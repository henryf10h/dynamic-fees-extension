// SPDX-License-Identifier: MIT

use starknet::ContractAddress;
use ekubo::types::keys::{PoolKey};
use ekubo::interfaces::core::{
    ICoreDispatcher, SwapParameters
};
use relaunch::contracts::internal_swap_pool::{ISPSwapResult, ClaimableFees};
   
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