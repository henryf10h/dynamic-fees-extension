// SPDX-License-Identifier: MIT
#[starknet::contract]
pub mod PositionManager {
    use core::array::{ArrayTrait};
    use core::serde::Serde;
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{consume_callback_data};
    use ekubo::components::upgradeable::{Upgradeable as upgradeable_component, IHasInterface};
    use ekubo::interfaces::core::{
        IExtension, SwapParameters, UpdatePositionParameters, IForwardee, ICoreDispatcher,
        ICoreDispatcherTrait, ILocker
    };
    use ekubo::types::bounds::{Bounds};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::types::delta::{Delta};
    use ekubo::types::i129::{i129};
    use ekubo::types::keys::{PoolKey};
    use starknet::{ContractAddress, get_contract_address};
    use starknet::storage::{
        StoragePointerReadAccess
    };
    // use ekubo::interfaces::mathlib::{IMathLibDispatcher};

    // Import our ISP component
    use relaunch::contracts::internal_swap_pool::{isp_component};
    use relaunch::contracts::internal_swap_pool::{ClaimableFees, ISPSwapData};

    #[abi(embed_v0)]
    impl Clear = ekubo::components::clear::ClearImpl<ContractState>;

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl Upgradeable = upgradeable_component::UpgradeableImpl<ContractState>;

    // ISP Component
    component!(path: isp_component, storage: isp, event: ISPEvent);
    impl ISPImpl = isp_component::ISPImpl<ContractState>;
    impl ISPInternal = isp_component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage,
        #[substorage(v0)]
        owned: owned_component::Storage,
        #[substorage(v0)]
        isp: isp_component::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        core: ICoreDispatcher,
        native_token: ContractAddress,
        // math: IMathLibDispatcher
    ) {
        self.initialize_owned(owner);
        
        // Pass the dispatcher to initialize
        ISPImpl::initialize(ref self, native_token, core, 30);
        
        // Set call points - minimal requirements for ISP
        core.set_call_points(
            CallPoints {
                before_initialize_pool: false,
                after_initialize_pool: false,
                before_swap: true,
                after_swap: false,
                before_update_position: false,
                after_update_position: false,
                before_collect_fees: false,
                after_collect_fees: false,
            }
        );
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapProcessed {
        #[key]
        pub pool_key: PoolKey,
        #[key]
        pub user: ContractAddress,
        pub prefill_amount: u128,
        pub swap_amount: u128,
        pub fee_collected: u128,
        pub total_output: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        SwapProcessed: SwapProcessed,
        #[flat]
        UpgradeableEvent: upgradeable_component::Event,
        #[flat]
        OwnedEvent: owned_component::Event,
        #[flat]
        ISPEvent: isp_component::Event,
    }

    // Implement IHasInterface for contract identification
    #[abi(embed_v0)]
    impl PositionManagerHasInterface of IHasInterface<ContractState> {
        fn get_primary_interface_id(self: @ContractState) -> felt252 {
            selector!("relaunch::contracts::position_manager::PositionManager")
        }
    }

    // Minimal extension implementation - only required to be a valid extension
    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        // All hooks return immediately - ISP logic happens in forwarded()
        fn before_initialize_pool(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129) {}
        fn after_initialize_pool(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129) {}
        fn before_swap(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, params: SwapParameters) {
            // Allow swaps only from this contract (ISP component calling swap)
            // Block all external direct swaps - they must go through ISP
            // This is a security measure to prevent direct swaps
            // from bypassing the ISP logic
            let contract_address = get_contract_address();
            assert(caller == contract_address, 'Only Position_manager for swaps');
        }
        fn after_swap(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, params: SwapParameters, delta: Delta) {}
        fn before_update_position(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, params: UpdatePositionParameters) {}
        fn after_update_position(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, params: UpdatePositionParameters, delta: Delta) {}
        fn before_collect_fees(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, salt: felt252, bounds: Bounds) {}
        fn after_collect_fees(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, salt: felt252, bounds: Bounds, delta: Delta) {}
    }

    // Core ISP logic - handles forwarded calls from router
    #[abi(embed_v0)]
    impl ForwardeeImpl of IForwardee<ContractState> {
        fn forwarded(
            ref self: ContractState,
            original_locker: ContractAddress,
            id: u32,
            data: Span<felt252>
        ) -> Span<felt252> {
            let core = self.isp.core.read();
            
            // Consume the callback data from router
            let swap_data = consume_callback_data::<ISPSwapData>(core, data);
            
            // Execute the ISP swap with prefill logic and output fee collection
            let result = ISPImpl::execute_isp_swap(
                ref self,
                swap_data.pool_key,
                swap_data.params,
                swap_data.user,
                swap_data.max_fee_amount
            );
            
            // Calculate total output for event
            let total_output = if swap_data.params.is_token1 {
                result.total_delta.amount1.mag
            } else {
                result.total_delta.amount0.mag
            };

            // Emit event for tracking
            self.emit(SwapProcessed {
                pool_key: swap_data.pool_key,
                user: swap_data.user,
                prefill_amount: result.prefill_amount,
                swap_amount: result.swap_amount,
                fee_collected: result.fee_collected,
                total_output,
            });

            // Serialize and return the result
            let mut result_data = array![];
            Serde::serialize(@result, ref result_data);
            result_data.span()
        }
    }

    // Locker implementation - not used in normal flow
    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            // The router is the locker in our architecture
            // ISP logic happens through forwarded() via the lock-forward pattern
            let mut empty = array![];
            assert(false, 'Not a locker - use Router');
            empty.span()
        }
    }

    /// Public interface for ISP functionality
    #[starknet::interface]
    pub trait IPositionManagerISP<TContractState> {
        fn get_pool_fees(self: @TContractState, pool_key: PoolKey) -> ClaimableFees;
        
        fn can_use_prefill(
            self: @TContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> bool;
        
        fn get_native_token(self: @TContractState) -> ContractAddress;
    }

    // Public interface for ISP functionality
    #[abi(embed_v0)]
    impl PositionManagerImpl of IPositionManagerISP<ContractState> {
        /// Get accumulated fees for a pool
        fn get_pool_fees(self: @ContractState, pool_key: PoolKey) -> ClaimableFees {
            ISPImpl::get_pool_fees(self, pool_key)
        }

        /// Check if a swap can use prefill
        fn can_use_prefill(
            self: @ContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> bool {
            ISPImpl::can_use_prefill(self, pool_key, params)
        }

        /// Get native token address
        fn get_native_token(self: @ContractState) -> ContractAddress {
            self.isp.native_token.read()
        }
    }
}