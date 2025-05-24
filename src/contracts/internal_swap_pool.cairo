// SPDX-License-Identifier: MIT
use ekubo::interfaces::core::{
    ICoreDispatcher, SwapParameters
};
use ekubo::types::delta::{Delta};
use ekubo::types::keys::{PoolKey};
use starknet::{ContractAddress};

/// Fee accumulation structure for each pool
#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct ClaimableFees {
    pub amount0: u128,  // Native token (ETH) fees
    pub amount1: u128,  // Other token fees
}

/// Data passed through lock-forward for ISP swaps
#[derive(Copy, Drop, Serde)]
pub struct ISPSwapData {
    pub pool_key: PoolKey,
    pub params: SwapParameters,
    pub user: ContractAddress,
    pub max_fee_amount: u128, // Not used for exact input
}

/// Result of ISP swap operation
#[derive(Copy, Drop, Serde)]
pub struct ISPSwapResult {
    pub total_delta: Delta,           // Final delta for user (after fees)
    pub prefill_amount: u128,         // Amount prefilled from fees
    pub fee_collected: u128,          // Fee collected from output
    pub swap_amount: u128,            // Amount swapped through core
    pub output_amount: u128,          // Total output amount to send to user
    pub output_token: ContractAddress, // Token to send to user
}

#[starknet::interface]
pub trait IISP<TState> {
    fn initialize(
        ref self: TState,
        native_token: ContractAddress,
        core: ICoreDispatcher,
        fee_percentage: u128
    );
    fn get_pool_fees(self: @TState, pool_key: PoolKey) -> ClaimableFees;
    fn can_use_prefill(
        self: @TState,
        pool_key: PoolKey,
        params: SwapParameters
    ) -> bool;
    fn execute_isp_swap(
        ref self: TState,
        pool_key: PoolKey,
        params: SwapParameters,
        user: ContractAddress,
        max_fee_amount: u128
    ) -> ISPSwapResult;
    fn accumulate_fees(
        ref self: TState,
        pool_key: PoolKey,
        token: ContractAddress,
        amount: u128
    );
}

#[starknet::component]
pub mod isp_component {
    use super::{ClaimableFees, ISPSwapResult, IISP};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, SwapParameters};
    use ekubo::interfaces::mathlib::{
        IMathLibLibraryDispatcher, IMathLibDispatcherTrait, dispatcher as mathlib
    };
    use ekubo::types::delta::{Delta};
    use ekubo::types::i129::{i129};
    use ekubo::types::keys::{PoolKey, SavedBalanceKey};
    use starknet::{ContractAddress, get_contract_address};
    use starknet::storage::{Map, StoragePointerWriteAccess, StorageMapWriteAccess, StorageMapReadAccess, StoragePointerReadAccess};

    #[storage]
    pub struct Storage {
        /// Accumulated fees per pool
        pub pool_fees: Map<PoolKey, ClaimableFees>,
        /// Native token address (ETH equivalent)
        pub native_token: ContractAddress,
        /// Core contract for interactions
        pub core: ICoreDispatcher,
        /// Fee percentage (in basis points, e.g., 30 = 0.3%)
        pub fee_percentage: u128,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        FeesAccumulated: FeesAccumulated,
        PrefillExecuted: PrefillExecuted,
        OutputFeeCollected: OutputFeeCollected,
        SwapFeeCollected: SwapFeeCollected,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeesAccumulated {
        #[key]
        pub pool_key: PoolKey,
        pub token: ContractAddress,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PrefillExecuted {
        #[key]
        pub pool_key: PoolKey,
        #[key]
        pub user: ContractAddress,
        pub prefill_amount: u128,
        pub eth_saved: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OutputFeeCollected {
        #[key]
        pub pool_key: PoolKey,
        #[key]
        pub user: ContractAddress,
        pub output_token: ContractAddress,
        pub fee_amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapFeeCollected {
        #[key]
        pub pool_key: PoolKey,
        pub token: ContractAddress,
        pub amount: u128,
    }

    #[embeddable_as(ISPImpl)]
    pub impl ISPEmbeddable<
        TContractState, +HasComponent<TContractState>
    > of IISP<ComponentState<TContractState>> {
        /// Initialize the ISP component
        fn initialize(
            ref self: ComponentState<TContractState>,
            native_token: ContractAddress,
            core: ICoreDispatcher,
            fee_percentage: u128
        ) {
            self.native_token.write(native_token);
            self.core.write(core);
            self.fee_percentage.write(fee_percentage);
        }

        /// Get accumulated fees for a pool
        fn get_pool_fees(
            self: @ComponentState<TContractState>, 
            pool_key: PoolKey
        ) -> ClaimableFees {
            self.pool_fees.read(pool_key)
        }

        /// Check if prefill can be used for this swap
        fn can_use_prefill(
            self: @ComponentState<TContractState>,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> bool {
            // Only prefill for ETH → Token swaps (exact input)
            if params.amount.sign {
                return false; // Not exact input
            }
            
            let native_is_token0 = self.native_token.read() == pool_key.token0;
            let is_eth_for_token = (native_is_token0 && !params.is_token1) || 
                                   (!native_is_token0 && params.is_token1);
            
            if !is_eth_for_token {
                return false;
            }

            // Check if we have accumulated token fees to use
            let fees = self.pool_fees.read(pool_key);
            if native_is_token0 {
                fees.amount1 > 0
            } else {
                fees.amount0 > 0
            }
        }

        /// Execute ISP swap with prefill logic and output fee collection
        fn execute_isp_swap(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            params: SwapParameters,
            user: ContractAddress,
            max_fee_amount: u128
        ) -> ISPSwapResult {
            let core = self.core.read();
            let math = mathlib();
            let native_token = self.native_token.read();
            
            // Determine token addresses
            let (token0_is_native, output_token) = if native_token == pool_key.token0 {
                (true, pool_key.token1)
            } else {
                (false, pool_key.token0)
            };
            
            // Check if we can use prefill
            let mut prefill_amount = 0_u128;
            let mut eth_saved = 0_u128;
            
            if self.can_use_prefill(pool_key, params) {
                // Get current pool price AND tick
                let pool_price = core.get_pool_price(pool_key);
                let current_tick = pool_price.tick;
                
                // Calculate prefill amounts using actual price range
                let available_token_fees = if token0_is_native {
                    self.pool_fees.read(pool_key).amount1
                } else {
                    self.pool_fees.read(pool_key).amount0
                };
                
                // Calculate how much ETH we can save by using available token fees
                eth_saved = InternalImpl::_calculate_eth_equivalent(
                    @self,
                    pool_key,
                    current_tick,
                    available_token_fees,
                    token0_is_native,
                    math
                );
                
                // Can't save more ETH than the input amount
                eth_saved = core::cmp::min(eth_saved, params.amount.mag);
                
                // Calculate how many tokens we need to prefill based on ETH saved
                prefill_amount = InternalImpl::_calculate_token_amount_from_eth(
                    @self,
                    pool_key,
                    current_tick,
                    eth_saved,
                    token0_is_native,
                    math
                );
                
                // Ensure we don't prefill more than available
                prefill_amount = core::cmp::min(prefill_amount, available_token_fees);
                
                if prefill_amount > 0 {
                    // Execute prefill: load tokens from saved fees
                    InternalImpl::_execute_prefill(
                        ref self, 
                        pool_key, 
                        prefill_amount, 
                        output_token
                    );
                    
                    self.emit(PrefillExecuted {
                        pool_key,
                        user,
                        prefill_amount,
                        eth_saved,
                    });
                }
            }
            
            // Calculate remaining swap amount
            let remaining_eth = if params.amount.mag > eth_saved {
                params.amount.mag - eth_saved
            } else {
                0
            };
            
            let mut swap_output = 0_u128;
            let mut swap_delta = Delta { amount0: i129 { mag: 0, sign: false }, amount1: i129 { mag: 0, sign: false } };
            
            if remaining_eth > 0 {
                // Execute remaining swap through core
                let remaining_params = SwapParameters {
                    amount: i129 { mag: remaining_eth, sign: false }, // Exact input
                    is_token1: params.is_token1,
                    sqrt_ratio_limit: params.sqrt_ratio_limit,
                    skip_ahead: params.skip_ahead,
                };
                
                swap_delta = core.swap(pool_key, remaining_params);
                
                // Get swap output amount
                swap_output = if params.is_token1 {
                    swap_delta.amount1.mag
                } else {
                    swap_delta.amount0.mag
                };
                
                // Collect fee from swap output (this is the missing part mentioned!)
                if swap_output > 0 {
                    let swap_fee = (swap_output * self.fee_percentage.read()) / 10000;
                    swap_output -= swap_fee;
                    
                    if swap_fee > 0 {
                        // Save the swap fee for future use
                        let saved_balance_key = SavedBalanceKey {
                            owner: get_contract_address(),
                            token: output_token,
                            salt: InternalImpl::_get_fee_salt(@self, pool_key, output_token),
                        };
                        core.save(saved_balance_key, swap_fee);
                        
                        // Update internal tracking
                        InternalImpl::_update_fee_tracking(ref self, pool_key, output_token, swap_fee);
                        
                        self.emit(SwapFeeCollected {
                            pool_key,
                            token: output_token,
                            amount: swap_fee,
                        });
                    }
                }
            }
            
            // Total output before final fee (prefill + swap after swap fee)
            let total_output_before_fee = prefill_amount + swap_output;
            
            // Calculate fee from prefill amount only (swap already had fee deducted)
            let prefill_fee = if prefill_amount > 0 {
                (prefill_amount * self.fee_percentage.read()) / 10000
            } else {
                0
            };
            
            let total_fee = prefill_fee + if remaining_eth > 0 {
                (swap_output * self.fee_percentage.read()) / 10000
            } else {
                0
            };
            
            let output_after_fee = total_output_before_fee - prefill_fee;
            
            // Save tokens for user withdrawal by router
            if output_after_fee > 0 {
                // Generate a unique salt for this user's withdrawal
                let user_salt = InternalImpl::_get_user_withdrawal_salt(@self, user);
                let user_balance_key = SavedBalanceKey {
                    owner: get_contract_address(),
                    token: output_token,
                    salt: user_salt,
                };
                core.save(user_balance_key, output_after_fee);
            }
            
            // Save the prefill fee
            if prefill_fee > 0 {
                let saved_balance_key = SavedBalanceKey {
                    owner: get_contract_address(),
                    token: output_token,
                    salt: InternalImpl::_get_fee_salt(@self, pool_key, output_token),
                };
                core.save(saved_balance_key, prefill_fee);
                
                // Update internal tracking
                InternalImpl::_update_fee_tracking(ref self, pool_key, output_token, prefill_fee);
                
                self.emit(OutputFeeCollected {
                    pool_key,
                    user,
                    output_token,
                    fee_amount: prefill_fee,
                });
            }
            
            // Create final delta representing user's perspective
            let total_delta = if params.is_token1 {
                Delta {
                    amount0: swap_delta.amount0,
                    amount1: i129 { mag: output_after_fee, sign: true }
                }
            } else {
                Delta {
                    amount0: i129 { mag: output_after_fee, sign: true },
                    amount1: swap_delta.amount1
                }
            };
            
            ISPSwapResult {
                total_delta,
                prefill_amount,
                fee_collected: total_fee,
                swap_amount: remaining_eth,
                output_amount: output_after_fee,
                output_token,
            }
        }

        /// Accumulate fees from external sources
        fn accumulate_fees(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            token: ContractAddress,
            amount: u128
        ) {
            InternalImpl::_update_fee_tracking(ref self, pool_key, token, amount);
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        /// Calculate price bounds using tick spacing
        fn _get_price_bounds(
            self: @ComponentState<TContractState>,
            pool_key: PoolKey,
            current_tick: i129,
            mathlib: IMathLibLibraryDispatcher
        ) -> (u256, u256) {
            // Use pool's tick spacing for accurate price calculation
            let tick_spacing = pool_key.tick_spacing;
            
            // Align to tick spacing
            let aligned_tick = if current_tick.mag % tick_spacing == 0 {
                current_tick
            } else {
                // Round down to nearest tick spacing
                let remainder = current_tick.mag % tick_spacing;
                if current_tick.sign {
                    // Negative tick
                    i129 { mag: current_tick.mag + (tick_spacing - remainder), sign: true }
                } else {
                    // Positive tick
                    i129 { mag: current_tick.mag - remainder, sign: false }
                }
            };
            
            // Get sqrt ratios for the range
            let sqrt_ratio_lower = mathlib.tick_to_sqrt_ratio(aligned_tick);
            let sqrt_ratio_upper = mathlib.tick_to_sqrt_ratio(
                aligned_tick + i129 { mag: tick_spacing, sign: false }
            );
            
            (sqrt_ratio_lower, sqrt_ratio_upper)
        }

        /// Calculate ETH equivalent of token amount using proper price range
        fn _calculate_eth_equivalent(
            self: @ComponentState<TContractState>,
            pool_key: PoolKey,
            current_tick: i129,
            token_amount: u128,
            token0_is_native: bool,
            mathlib: IMathLibLibraryDispatcher
        ) -> u128 {
            let (sqrt_ratio_lower, sqrt_ratio_upper) = self._get_price_bounds(
                pool_key, current_tick, mathlib
            );
            
            if token0_is_native {
                // ETH is token0, we have token1
                // Calculate amount0 needed for given amount1
                mathlib.amount0_delta(sqrt_ratio_lower, sqrt_ratio_upper, token_amount, false)
            } else {
                // ETH is token1, we have token0
                // Calculate amount1 needed for given amount0
                mathlib.amount1_delta(sqrt_ratio_lower, sqrt_ratio_upper, token_amount, false)
            }
        }
        
        /// Calculate token amount from ETH using proper price range
        fn _calculate_token_amount_from_eth(
            self: @ComponentState<TContractState>,
            pool_key: PoolKey,
            current_tick: i129,
            eth_amount: u128,
            token0_is_native: bool,
            mathlib: IMathLibLibraryDispatcher
        ) -> u128 {
            let (sqrt_ratio_lower, sqrt_ratio_upper) = self._get_price_bounds(
                pool_key, current_tick, mathlib
            );
            
            if token0_is_native {
                // ETH is token0, calculate token1 amount
                mathlib.amount1_delta(sqrt_ratio_lower, sqrt_ratio_upper, eth_amount, false)
            } else {
                // ETH is token1, calculate token0 amount
                mathlib.amount0_delta(sqrt_ratio_lower, sqrt_ratio_upper, eth_amount, false)
            }
        }
        
        /// Execute prefill operation - load tokens from saved fees
        fn _execute_prefill(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            token_amount: u128,
            token: ContractAddress
        ) {
            let core = self.core.read();
            
            // Load tokens from saved fees
            let token_balance_key = SavedBalanceKey {
                owner: get_contract_address(),
                token,
                salt: self._get_fee_salt(pool_key, token),
            };
            
            // Load the tokens we'll give from fees
            core.load(token, token_balance_key.salt, token_amount);
            
            // Update fee tracking
            let mut current_fees = self.pool_fees.read(pool_key);
            
            if token == pool_key.token0 {
                current_fees.amount0 -= token_amount;
            } else {
                current_fees.amount1 -= token_amount;
            }
            self.pool_fees.write(pool_key, current_fees);
        }
        
        /// Update fee tracking after collecting fees
        fn _update_fee_tracking(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            token: ContractAddress,
            amount: u128
        ) {
            // Update internal tracking
            let mut current_fees = self.pool_fees.read(pool_key);
            
            if token == pool_key.token0 {
                current_fees.amount0 += amount;
            } else {
                current_fees.amount1 += amount;
            }
            self.pool_fees.write(pool_key, current_fees);
            
            self.emit(FeesAccumulated { pool_key, token, amount });
        }
        
        /// Generate salt for saved balance key
        fn _get_fee_salt(
            self: @ComponentState<TContractState>,
            pool_key: PoolKey,
            token: ContractAddress
        ) -> felt252 {
            // Simple salt generation based on pool and token
            let token_felt: felt252 = token.into();
            let fee_felt: felt252 = pool_key.fee.into();
            token_felt + fee_felt
        }
        
        /// Generate salt for user withdrawal
        fn _get_user_withdrawal_salt(
            self: @ComponentState<TContractState>,
            user: ContractAddress
        ) -> felt252 {
            // Simple salt based on user address
            let user_felt: felt252 = user.into();
            user_felt + 'user_withdrawal'
        }
    }
}