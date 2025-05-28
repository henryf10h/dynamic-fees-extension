// SPDX-License-Identifier: MIT
#[starknet::contract]
pub mod ISPRouter {
    use core::array::{ArrayTrait};
    use core::traits::Into;
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, forward_lock
    };
    use ekubo::components::util::{serialize};
    use ekubo::types::i129::{i129};
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, SwapParameters, IForwardeeDispatcher, ILocker
    };
    use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::keys::{PoolKey};
    use starknet::{get_contract_address, get_caller_address, ContractAddress};
    use starknet::storage::{
        StoragePointerWriteAccess,
        StoragePointerReadAccess};

    // Import ISP types
    use relaunch::contracts::internal_swap_pool::{ISPSwapData, ISPSwapResult, ClaimableFees};
    
    // Position manager interface
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
        pub fee_collected: u128,
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

    /// Interface for ISP Router
    #[starknet::interface]
    pub trait IISPRouter<TContractState> {
        fn swap(
            ref self: TContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            token_in: ContractAddress,
            amount_in: u128,
            
            
        ) -> ISPSwapResult;

        fn preview_isp_swap(
            self: @TContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> (bool, ClaimableFees, u128);
    }

    #[abi(embed_v0)]
    impl ISPRouterImpl of IISPRouter<ContractState> {
        /// Main swap function - uses lock-forward pattern for ISP
        fn swap(
            ref self: ContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            token_in: ContractAddress,
            amount_in: u128,
            
            
        ) -> ISPSwapResult {
            
            
            // Verify this is an exact input swap
            assert(!params.amount.sign, 'Only exact input swaps');
            assert(params.amount.mag == amount_in, 'Amount mismatch');
            
            // Verify token_in matches the swap direction
            let is_token0_to_token1 = !params.is_token1;
            if is_token0_to_token1 {
                assert(token_in == pool_key.token0, 'Token mismatch');
            } else {
                assert(token_in == pool_key.token1, 'Token mismatch');
            }

            let caller = get_caller_address();
            
            // Prepare callback data
            let callback_data = CallbackData {
                caller,
                pool_key,
                params,
                token_in,
                amount_in,
                
            };
            
            // Use the helper to call core.lock with our callback
            call_core_with_callback::<CallbackData, ISPSwapResult>(
                self.core.read(),
                @callback_data
            )
        }
        
        /// Preview potential ISP prefill with proper price calculation
        fn preview_isp_swap(
            self: @ContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> (bool, ClaimableFees, u128) {
            let isp_manager = IPositionManagerISPDispatcher { contract_address: pool_key.extension };
            let available_fees = IPositionManagerISPDispatcherTrait::get_pool_fees(isp_manager, pool_key);
            let can_prefill = IPositionManagerISPDispatcherTrait::can_use_prefill(isp_manager, pool_key, params);
            
            let potential_prefill_eth = if can_prefill {
                // Get current pool price AND tick
                let pool_price = self.core.read().get_pool_price(pool_key);
                let current_tick = pool_price.tick;
                let mathlib = mathlib();
                
                // Determine which token is native and which fees are available
                let native_token = IPositionManagerISPDispatcherTrait::get_native_token(isp_manager);
                let token0_is_native = native_token == pool_key.token0;
                
                // If we're swapping ETH for tokens, we need token fees (non-ETH)
                let available_output_fees = if token0_is_native {
                    // Native is token0, so we need token1 fees for ETH→Token1 swap
                    if !params.is_token1 {
                        available_fees.amount1  // Swapping token0 (ETH) for token1
                    } else {
                        0  // Can't prefill Token1→ETH swap
                    }
                } else if params.is_token1 {
                    // Native is token1, so we need token0 fees for ETH→Token0 swap
                    available_fees.amount0  // Swapping token1 (ETH) for token0
                } else {
                    0  // Can't prefill Token0→ETH swap
                };
                
                if available_output_fees > 0 {
                    // Get price bounds based on tick spacing
                    let tick_spacing = pool_key.tick_spacing;
                    
                    // Align to tick spacing
                    let aligned_tick = if current_tick.mag % tick_spacing == 0 {
                        current_tick
                    } else {
                        let remainder = current_tick.mag % tick_spacing;
                        if current_tick.sign {
                            i129 { mag: current_tick.mag + (tick_spacing - remainder), sign: true }
                        } else {
                            i129 { mag: current_tick.mag - remainder, sign: false }
                        }
                    };
                    
                    // Get sqrt ratios for the range
                    let sqrt_ratio_lower = mathlib.tick_to_sqrt_ratio(aligned_tick);
                    let sqrt_ratio_upper = mathlib.tick_to_sqrt_ratio(
                        aligned_tick + i129 { mag: tick_spacing, sign: false }
                    );
                    
                    // Calculate ETH equivalent using proper price range
                    let eth_equivalent = if token0_is_native {
                        // ETH is token0, we have token1 fees
                        mathlib.amount0_delta(
                            sqrt_ratio_lower, 
                            sqrt_ratio_upper,
                            available_output_fees,
                            false
                        )
                    } else {
                        // ETH is token1, we have token0 fees
                        mathlib.amount1_delta(
                            sqrt_ratio_lower, 
                            sqrt_ratio_upper,
                            available_output_fees,
                            false
                        )
                    };
                    
                    // Don't prefill more than the swap amount
                    core::cmp::min(eth_equivalent, params.amount.mag)
                } else {
                    0
                }
            } else {
                0
            };

            (can_prefill, available_fees, potential_prefill_eth)
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

    // Locker implementation - this is where the core logic happens
    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            
            // Consume the callback data
            let callback_data = consume_callback_data::<CallbackData>(core, data);
            
            // Transfer input tokens from caller to router
            let token_in_contract = IERC20Dispatcher { contract_address: callback_data.token_in };
            let amount_in_u256: u256 = callback_data.amount_in.into();
            token_in_contract.transferFrom(callback_data.caller, get_contract_address(), amount_in_u256);
            
            // Approve and pay to core
            token_in_contract.approve(core.contract_address, amount_in_u256);
            core.pay(callback_data.token_in);
            
            // Prepare ISP swap data
            let isp_data = ISPSwapData {
                pool_key: callback_data.pool_key,
                params: callback_data.params,
                user: callback_data.caller,
                max_fee_amount: 0, // Not used for exact input swaps
            };
            
            // Forward to ISP extension and get result
            let isp_result: ISPSwapResult = forward_lock(
                core,
                IForwardeeDispatcher { contract_address: callback_data.pool_key.extension },
                @isp_data
            );
            
            
            // FIXED: Now we need to withdraw the tokens to the user
            // The ISP has saved the output tokens for the user, we need to load and withdraw them
            if isp_result.output_amount > 0 {
                // Load the tokens that ISP saved for the user
                // let user_salt = InternalImpl::_get_user_withdrawal_salt(
                //     @self,
                //     callback_data.caller
                // );
                // core.load(isp_result.output_token, user_salt, isp_result.output_amount);
                
                // Withdraw the tokens to the user
                core.withdraw(isp_result.output_token, callback_data.caller, isp_result.output_amount);
            }
            
            // Emit event
            self.emit(SwapExecuted {
                pool_key: callback_data.pool_key,
                user: callback_data.caller,
                amount_in: callback_data.amount_in,
                amount_out: isp_result.output_amount,
                fee_collected: isp_result.fee_collected,
            });
            
            // Return the result using serialize helper
            serialize(@isp_result).span()
        }
    }
}