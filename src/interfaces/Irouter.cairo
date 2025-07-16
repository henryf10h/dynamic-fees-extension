use starknet::ContractAddress;
use ekubo::types::keys::{PoolKey};
use ekubo::types::delta::{Delta};
use ekubo::types::i129::{i129};

    #[derive(Serde, Copy, Drop)]
    pub struct RouteNode {
        pub pool_key: PoolKey,
        pub sqrt_ratio_limit: u256,
        pub skip_ahead: u128,
    }

    // Amount of token to swap and its address
    #[derive(Serde, Copy, Drop)]
    pub struct TokenAmount {
        pub token: ContractAddress,
        pub amount: i129,
    }

    // Swap argument for multi multi-hop swaps
    // After single swap works well change to: pub route: Array<RouteNode>
    #[derive(Serde, Drop)]
    pub struct Swap {
        pub route: RouteNode,
        pub token_amount: TokenAmount,
    }
    
    // Interface for ISP Router
    #[starknet::interface]
    pub trait IISPRouter<TContractState> {
        fn swap( 
            ref self: TContractState, 
            swap_data: Swap
        ) -> Delta;
    }