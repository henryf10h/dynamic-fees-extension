// SPDX-License-Identifier: MIT

use starknet::ContractAddress;
use ekubo::types::keys::{PoolKey};
use ekubo::interfaces::core::{
    ICoreDispatcher, SwapParameters
};
   
    #[starknet::interface]
    pub trait IISP<TState> {
        fn initialize(
            ref self: TState,
            native_token: ContractAddress,
            core: ICoreDispatcher,
            fee_percentage: u128
        );
        fn can_use_prefill(
            self: @TState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> bool;
        fn accumulate_fees(
            ref self: TState,
            pool_key: PoolKey,
            token: ContractAddress,
            amount: u128
        );
        fn get_native_token(self: @TState) -> ContractAddress;
        fn calc_fee(ref self: TState, amount: u128) -> u128;
    }