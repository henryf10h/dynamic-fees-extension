// SPDX-License-Identifier: MIT
#[starknet::contract]
pub mod ISPRouter {
    use core::array::{ArrayTrait};
    use core::traits::Into;
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{
        call_core_with_callback, 
        consume_callback_data, 
        forward_lock, 
        handle_delta
    };
    use ekubo::components::util::{serialize};
    use ekubo::types::i129::{i129};
    use ekubo::types::delta::{Delta};
    use ekubo::types::keys::{PoolKey};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::interfaces::core::{
        ICoreDispatcher, 
        ICoreDispatcherTrait, 
        SwapParameters, 
        IForwardeeDispatcher, 
        ILocker
    };
    use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{get_contract_address, get_caller_address, ContractAddress};
    use starknet::storage::{StoragePointerWriteAccess, StoragePointerReadAccess};
    use relaunch::interfaces::Irouter::{IISPRouter};
    use relaunch::interfaces::Irouter::{Swap, RouteNode, TokenAmount};

    #[abi(embed_v0)]
    impl Clear = ekubo::components::clear::ClearImpl<ContractState>;

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        native_token: ContractAddress,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        core: ICoreDispatcher,
        native_token: ContractAddress,
    ) {
        self.initialize_owned(owner);
        self.core.write(core);
        self.native_token.write(native_token);
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapExecuted {
        #[key]
        pub pool_key: PoolKey,
        #[key]
        pub user: ContractAddress,
        pub amount_in: u128,
        pub amount_out: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        SwapExecuted: SwapExecuted,
        #[flat]
        OwnedEvent: owned_component::Event,
    }

    // Storage for callback data
    #[derive(Copy, Drop, Serde)]
    struct CallbackData {
        caller: ContractAddress,
        pool_key: PoolKey,
        params: SwapParameters,
        token_in: ContractAddress,
        amount_in: u128,
        
    }

    #[abi(embed_v0)]
    impl ISPRouterImpl of IISPRouter<ContractState> {

        /// Main swap function - uses lock-forward pattern for ISP
        fn swap( ref self: ContractState, swap_data: Swap) -> Delta {
            // Use the helper to call core.lock with our callback
            call_core_with_callback( self.core.read(), @swap_data )
        }
    }

    // Locker implementation - this is where the core logic happens
    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            // Consume the callback data
            let swap_data : Swap = consume_callback_data(core, data);

            // Forward to InternalSwapPool extension and get result
            let isp_delta: Delta = forward_lock(
                core,
                IForwardeeDispatcher { contract_address: swap_data.route.pool_key.extension },
                @swap_data
            );

            let recipient = get_contract_address();

            // Handle deltas - no sign manipulation needed!
            // The delta represents the pool's perspective:
            // - Positive delta = pool owes tokens (router receives)
            // - Negative delta = router owes tokens to pool (router pays)
            handle_delta(core, swap_data.route.pool_key.token0, isp_delta.amount0, recipient);
            handle_delta(core, swap_data.route.pool_key.token1, isp_delta.amount1, recipient);

            // Return the result using serialize helper
            serialize(@isp_delta).span()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Generate salt for user withdrawal from ISP
        fn _get_user_withdrawal_salt(
            self: @ContractState,
            user: ContractAddress
        ) -> felt252 {
            // Must match the salt generation in ISP component
            let user_felt: felt252 = user.into();
            user_felt + 'user_withdrawal'
        }
    }
}
