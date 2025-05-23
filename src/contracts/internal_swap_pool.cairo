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
    pub max_fee_amount: u128, // Max fee user is willing to pay
}

/// Result of ISP swap operation
#[derive(Copy, Drop, Serde)]
pub struct ISPSwapResult {
    pub total_delta: Delta,           // Combined result for user
    pub prefill_amount: u128,         // Amount prefilled from fees
    pub fee_collected: u128,          // Fee collected from user
    pub swap_amount: u128,            // Amount swapped through core
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
        pub fee_collected: u128,
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
            // Only prefill for ETH → Token swaps
            let native_is_token0 = self.native_token.read() == pool_key.token0;
            let is_eth_for_token = (native_is_token0 && !params.is_token1) || 
                                   (!native_is_token0 && params.is_token1);
            
            if !is_eth_for_token {
                return false;
            }

            // Check if we have accumulated token fees to use
            let fees = self.pool_fees.read(pool_key);
            fees.amount1 > 0
        }

        /// Execute ISP swap with prefill logic - this is the core ISP function
        fn execute_isp_swap(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            params: SwapParameters,
            user: ContractAddress,
            max_fee_amount: u128
        ) -> ISPSwapResult {
            let core = self.core.read();
            
            // Check if we can use prefill
            if !self.can_use_prefill(pool_key, params) {
                // No prefill possible - execute regular swap
                let delta = core.swap(pool_key, params);
                return ISPSwapResult {
                    total_delta: delta,
                    prefill_amount: 0,
                    fee_collected: 0,
                    swap_amount: if params.is_token1 { delta.amount1.mag } else { delta.amount0.mag },
                };
            }

            // Calculate prefill amounts
            let available_token_fees = self.pool_fees.read(pool_key).amount1;
            let prefill_amount = InternalImpl::_calculate_prefill_amount(@self, params, available_token_fees);
            
            if prefill_amount == 0 {
                // No prefill possible - execute regular swap
                let delta = core.swap(pool_key, params);
                return ISPSwapResult {
                    total_delta: delta,
                    prefill_amount: 0,
                    fee_collected: 0,
                    swap_amount: if params.is_token1 { delta.amount1.mag } else { delta.amount0.mag },
                };
            }

            // Calculate fee to collect
            let fee_amount = InternalImpl::_calculate_fee(@self, prefill_amount);
            assert(fee_amount <= max_fee_amount, 'Fee exceeds maximum');

            // Execute the prefill operation
            let prefill_delta = InternalImpl::_execute_prefill(ref self, pool_key, prefill_amount, fee_amount, user);
            
            // Calculate remaining swap if needed
            let remaining_amount = if params.amount.mag > prefill_amount {
                params.amount.mag - prefill_amount
            } else {
                0
            };

            let (total_delta, swap_amount) = if remaining_amount > 0 {
                // Execute remaining swap through core
                let remaining_params = SwapParameters {
                    amount: i129 { mag: remaining_amount, sign: params.amount.sign },
                    is_token1: params.is_token1,
                    sqrt_ratio_limit: params.sqrt_ratio_limit,
                    skip_ahead: params.skip_ahead,
                };
                
                let swap_delta = core.swap(pool_key, remaining_params);
                
                // Combine prefill and swap deltas
                let combined_delta = InternalImpl::_combine_deltas(@self, prefill_delta, swap_delta);
                (combined_delta, remaining_amount)
            } else {
                // Only prefill, no additional swap needed
                (prefill_delta, 0)
            };

            self.emit(PrefillExecuted {
                pool_key,
                user,
                prefill_amount,
                fee_collected: fee_amount,
            });

            ISPSwapResult {
                total_delta,
                prefill_amount,
                fee_collected: fee_amount,
                swap_amount,
            }
        }

        /// Accumulate fees from router (when users pay fees for swaps)
        fn accumulate_fees(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            token: ContractAddress,
            amount: u128
        ) {
            // Save the fees in core for later use
            let saved_balance_key = SavedBalanceKey {
                owner: get_contract_address(),
                token,
                salt: InternalImpl::_get_fee_salt(@self, pool_key, token),
            };
            
            self.core.read().save(saved_balance_key, amount);

            // Update internal tracking
            let mut current_fees = self.pool_fees.read(pool_key);
            if token == self.native_token.read() {
                current_fees.amount0 += amount;
            } else {
                current_fees.amount1 += amount;
            }
            self.pool_fees.write(pool_key, current_fees);
            
            self.emit(FeesAccumulated { pool_key, token, amount });
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        /// Calculate maximum prefill amount based on available fees and swap params
        fn _calculate_prefill_amount(
            self: @ComponentState<TContractState>,
            params: SwapParameters,
            available_fees: u128
        ) -> u128 {
            if available_fees == 0 {
                return 0;
            }

            if params.amount.sign {
                // Exact output - can prefill up to the full requested amount
                core::cmp::min(available_fees, params.amount.mag)
            } else {
                // Exact input - calculate max tokens we can provide for the ETH input
                // For simplicity, assume we can prefill up to available fees
                // In production, this would use proper price calculations
                core::cmp::min(available_fees, params.amount.mag)
            }
        }

        /// Calculate fee for prefill operation
        fn _calculate_fee(
            self: @ComponentState<TContractState>,
            prefill_amount: u128
        ) -> u128 {
            (prefill_amount * self.fee_percentage.read()) / 10000
        }

        /// Execute the actual prefill: take ETH from user, give tokens from fees
        fn _execute_prefill(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            prefill_amount: u128,
            fee_amount: u128,
            user: ContractAddress
        ) -> Delta {
            let core = self.core.read();
            let native_token = self.native_token.read();
            
            // Determine token addresses
            let (eth_token, other_token) = if native_token == pool_key.token0 {
                (pool_key.token0, pool_key.token1)
            } else {
                (pool_key.token1, pool_key.token0)
            };

            // Take ETH fee from user (core.pay() will be called from router)
            // The router should have already called core.pay() for the ETH

            // Load tokens from saved fees to give to user
            let token_balance_key = SavedBalanceKey {
                owner: get_contract_address(),
                token: other_token,
                salt: self._get_fee_salt(pool_key, other_token),
            };

            // Load the tokens we'll give to user
            core.load(other_token, token_balance_key.salt, prefill_amount);
            
            // Withdraw tokens to user
            core.withdraw(other_token, user, prefill_amount);

            // Save the ETH fee we collected
            let eth_balance_key = SavedBalanceKey {
                owner: get_contract_address(),
                token: eth_token,
                salt: self._get_fee_salt(pool_key, eth_token),
            };
            
            core.save(eth_balance_key, fee_amount);

            // Update fee tracking
            self._update_fees_after_prefill(pool_key, prefill_amount, fee_amount);

            // Create delta representing the prefill operation
            if native_token == pool_key.token0 {
                Delta {
                    amount0: i129 { mag: fee_amount, sign: false },      // ETH taken as fee
                    amount1: i129 { mag: prefill_amount, sign: true }    // Tokens given to user
                }
            } else {
                Delta {
                    amount0: i129 { mag: prefill_amount, sign: true },   // Tokens given to user
                    amount1: i129 { mag: fee_amount, sign: false }       // ETH taken as fee
                }
            }
        }

        /// Update fee balances after prefill
        fn _update_fees_after_prefill(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            tokens_used: u128,
            eth_collected: u128
        ) {
            let mut current_fees = self.pool_fees.read(pool_key);
            
            // Reduce token fees used for prefill
            current_fees.amount1 = if current_fees.amount1 >= tokens_used {
                current_fees.amount1 - tokens_used
            } else {
                0
            };
            
            // Increase ETH fees collected
            current_fees.amount0 += eth_collected;
            
            self.pool_fees.write(pool_key, current_fees);
        }

        /// Combine two deltas
        fn _combine_deltas(
            self: @ComponentState<TContractState>,
            delta1: Delta,
            delta2: Delta
        ) -> Delta {
            let amount0_combined = if delta1.amount0.sign == delta2.amount0.sign {
                // Same sign, add magnitudes
                i129 { mag: delta1.amount0.mag + delta2.amount0.mag, sign: delta1.amount0.sign }
            } else if delta1.amount0.mag >= delta2.amount0.mag {
                // Different signs, subtract magnitudes
                i129 { mag: delta1.amount0.mag - delta2.amount0.mag, sign: delta1.amount0.sign }
            } else {
                i129 { mag: delta2.amount0.mag - delta1.amount0.mag, sign: delta2.amount0.sign }
            };

            let amount1_combined = if delta1.amount1.sign == delta2.amount1.sign {
                // Same sign, add magnitudes
                i129 { mag: delta1.amount1.mag + delta2.amount1.mag, sign: delta1.amount1.sign }
            } else if delta1.amount1.mag >= delta2.amount1.mag {
                // Different signs, subtract magnitudes
                i129 { mag: delta1.amount1.mag - delta2.amount1.mag, sign: delta1.amount1.sign }
            } else {
                i129 { mag: delta2.amount1.mag - delta1.amount1.mag, sign: delta2.amount1.sign }
            };

            Delta {
                amount0: amount0_combined,
                amount1: amount1_combined,
            }
        }

        /// Generate salt for saved balance key
        fn _get_fee_salt(
            self: @ComponentState<TContractState>,
            pool_key: PoolKey,
            token: ContractAddress
        ) -> felt252 {
            // Simple salt generation based on pool and token
            // In production, use proper hashing
            let token_felt: felt252 = token.into();
            let fee_felt: felt252 = pool_key.fee.into();
            token_felt + fee_felt
        }
    }
}