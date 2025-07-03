   use starknet::ContractAddress;
   use ekubo::interfaces::core::{SwapParameters};
   use ekubo::types::keys::{PoolKey};
   use relaunch::contracts::internal_swap_pool::{ISPSwapResult};
    
    // Interface for ISP Router
    #[starknet::interface]
    pub trait IISPRouter<TContractState> {
        fn swap(
            ref self: TContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            token_in: ContractAddress,
            amount_in: u128
        ) -> ISPSwapResult;
    }