use snforge_std::{declare, spy_events, EventSpyAssertionsTrait};
use starknet::ContractAddress;
use core::result::ResultTrait;

// Define required interfaces locally
#[starknet::interface]
trait IERC20<TContractState> {
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u128);
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u128);
    fn balance_of(self: @TContractState, account: ContractAddress) -> u128;
}

#[starknet::interface]
trait IISP<TContractState> {
    fn swap(
        ref self: TContractState,
        pool_key: PoolKey,
        params: SwapParameters,
        token_in: ContractAddress,
        amount_in: u128
    );
}

#[derive(Drop, Serde)]
struct PoolKey {
    token0: ContractAddress,
    token1: ContractAddress,
    extension: ContractAddress,
}

#[derive(Drop, Serde)]
struct SwapParameters {
    amount: i129,
    is_token1: bool,
    sqrt_price_limit: u128,
}

#[derive(Drop, Serde)]
struct i129 {
    mag: u128,
    sign: bool,
}

#[test]
fn test_router_swap() {
    // Deploy tokens
    let token_a_class = declare("ERC20_Token").unwrap().contract_class();
    let (token_a, _) = token_a_class.deploy(@array![]).unwrap();
    
    let token_b_class = declare("ERC20_Token").unwrap().contract_class();
    let (token_b, _) = token_b_class.deploy(@array![]).unwrap();

    // Deploy core (mock)
    let core_class = declare("EkuboCore_Mock").unwrap().contract_class();
    let (core, _) = core_class.deploy(@array![]).unwrap();

    // Deploy position manager
    let pm_class = declare("PositionManager").unwrap().contract_class();
    let (position_manager, _) = pm_class.deploy(@array![core.into(), token_a.into()]).unwrap();

    // Deploy router
    let router_class = declare("ISPRouter").unwrap().contract_class();
    let (router, _) = router_class.deploy(@array![core.into(), token_a.into()]).unwrap();

    // Initialize pool
    let pool_key = PoolKey {
        token0: token_a,
        token1: token_b,
        extension: position_manager,
    };

    // Setup test user
    let user: ContractAddress = 12345.try_into().unwrap();

    // Mint tokens and approve router
    IERC20Dispatcher { contract_address: token_a }.mint(user, 1000);
    IERC20Dispatcher { contract_address: token_a }.approve(router, 1000);

    // Prepare swap parameters
    let swap_params = SwapParameters {
        amount: i129 { mag: 100, sign: false },
        is_token1: false,
        sqrt_price_limit: 0,
    };

    // Execute swap
    let mut event_spy = spy_events();
    IISPDispatcher { contract_address: router }.swap(
        pool_key,
        swap_params,
        token_a,
        100
    );

    // Verify tokenB balance increased
    let balance = IERC20Dispatcher { contract_address: token_b }.balance_of(user);
    assert(balance > 0, "No output tokens received");
}
