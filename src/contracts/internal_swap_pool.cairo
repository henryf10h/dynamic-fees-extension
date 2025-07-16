// SPDX-License-Identifier: MIT

#[starknet::contract]
pub mod InternalSwapPool {
    use ekubo::interfaces::core::{
        IExtension, SwapParameters, UpdatePositionParameters, IForwardee, ICoreDispatcher,
        ICoreDispatcherTrait
    };
    use ekubo::types::delta::{Delta};
    use ekubo::types::keys::{PoolKey};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::types::bounds::{Bounds};
    use ekubo::types::i129::{i129};
    use starknet::{ContractAddress, get_contract_address};
    use starknet::storage::*;
    use core::array::{ArrayTrait};
    use core::serde::Serde;
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{consume_callback_data};
    use ekubo::components::upgradeable::{Upgradeable as upgradeable_component, IHasInterface};
    use relaunch::interfaces::Iisp::IISP;
    use relaunch::interfaces::Irouter::{Swap};

    #[abi(embed_v0)]
    impl Clear = ekubo::components::clear::ClearImpl<ContractState>;

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl Upgradeable = upgradeable_component::UpgradeableImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage,
        #[substorage(v0)]
        owned: owned_component::Storage,
        core: ICoreDispatcher,
        native_token: ContractAddress,
        fee_percentage: u256
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        core: ICoreDispatcher,
        native_token: ContractAddress,
    ) {
        self.initialize_owned(owner);
        
        // Set ISP fields directly
        self.native_token.write(native_token);
        self.core.write(core);
        self.fee_percentage.write(30); // 0.3%
        
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
        pub swap_amount: u128,
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
    }

    // Implement IHasInterface for contract identification
    #[abi(embed_v0)]
    impl InternalSwapPoolHasInterface of IHasInterface<ContractState> {
        fn get_primary_interface_id(self: @ContractState) -> felt252 {
            selector!("relaunch::contracts::internal_swap_pool::InternalSwapPool")
        }
    }

    // Minimal extension implementation
    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        fn before_initialize_pool(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129) {}
        fn after_initialize_pool(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129) {}
        fn before_swap(ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, params: SwapParameters) {
            panic!("Only from internal_swap_pool");
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
            let core = self.core.read();

            // Consume the callback data from router
            let swap_data : Swap = consume_callback_data(core, data);

            let is_token1 = swap_data.route.pool_key.token1 == swap_data.token_amount.token;

            // Execute the ISP swap
            let result : Delta = InternalSwapPoolImpl::execute_isp_swap(
                ref self,
                swap_data.route.pool_key,
                SwapParameters {
                    amount: swap_data.token_amount.amount,
                    is_token1: is_token1,
                    sqrt_ratio_limit: swap_data.route.sqrt_ratio_limit,
                    skip_ahead: swap_data.route.skip_ahead
                }
            );

            // Serialize and return the result
            let mut result_data = array![];
            Serde::serialize(@result, ref result_data);
            result_data.span()
        }
    }

// Public interface for ISP functionality
#[abi(embed_v0)]
impl InternalSwapPoolImpl of IISP<ContractState> {
        fn initialize(
            ref self: ContractState,
            native_token: ContractAddress,
            core: ICoreDispatcher,
            fee_percentage: u128
        ) {
            // Already initialized in constructor
        }

        fn can_use_prefill(
            self: @ContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> bool {
            false
        }


        fn accumulate_fees(
            ref self: ContractState,
            pool_key: PoolKey,
            token: ContractAddress,
            amount: u128
        ) {}

        /// Get native token address
        fn get_native_token(self: @ContractState) -> ContractAddress {
            self.native_token.read()
        }

        /// Execute basic ISP swap
        fn execute_isp_swap(
            ref self: ContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> Delta {
            let core = self.core.read();
            let delta = core.swap(pool_key, params);
            delta
        }
    }
}


