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
    pub total_delta: Delta,           // Final delta for user
    pub output_amount: u128,          // Total output amount
    pub output_token: ContractAddress, // Token to send to user
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

// ISP TODO:
// 1. New logic to get amounts from prices in V2 style
// 2. Get fees at the end of lock-forward pattern 
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
        // No events needed for basic swap
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

        /// Get accumulated fees for a pool (stub implementation)
        fn get_pool_fees(
            self: @ComponentState<TContractState>, 
            pool_key: PoolKey
        ) -> ClaimableFees {
            ClaimableFees { amount0: 0, amount1: 0 }
        }

        /// Stub implementation (not used in basic swap)
        fn can_use_prefill(
            self: @ComponentState<TContractState>,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> bool {
            false
        }

        /// Execute basic ISP swap without fees or prefill
        fn execute_isp_swap(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            params: SwapParameters,
            user: ContractAddress,
            max_fee_amount: u128
        ) -> ISPSwapResult {
            let core = self.core.read();
            let delta = core.swap(pool_key, params);
            
            // Calculate output amount based on swap direction
            let output_amount = if params.is_token1 {
                delta.amount1.mag
            } else {
                delta.amount0.mag
            };
            
            // Determine output token
            let output_token = if params.is_token1 {
                pool_key.token0
            } else {
                pool_key.token1
            };
            
            ISPSwapResult {
                total_delta: delta,
                output_amount,
                output_token,
                swap_amount: params.amount.mag
            }
        }

        /// Stub implementation (not used in basic swap)
        fn accumulate_fees(
            ref self: ComponentState<TContractState>,
            pool_key: PoolKey,
            token: ContractAddress,
            amount: u128
        ) {
            // No-op for basic swap
        }
    }

    // Internal implementation removed for basic swap functionality
}
