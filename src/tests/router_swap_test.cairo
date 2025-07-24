use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher, SwapParameters};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::types::keys::{PoolKey};
use ekubo::types::bounds::{Bounds};
use ekubo::types::i129::{i129};
use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
use core::num::traits::{Zero};
use relaunch::interfaces::Irouter::{IISPRouterDispatcher, IISPRouterDispatcherTrait, Swap, TokenAmount, RouteNode};
use relaunch::interfaces::Iisp::{IISPDispatcher, IISPDispatcherTrait};
use relaunch::contracts::test_token::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    declare, DeclareResultTrait, ContractClassTrait, ContractClass, cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp_global, CheatSpan,
};
use starknet::{get_block_timestamp, contract_address_const, ContractAddress, get_contract_address};

fn deploy_token(
    class: @ContractClass, recipient: ContractAddress, amount: u256
) -> IERC20Dispatcher {
    let (contract_address, _) = class
        .deploy(@array![recipient.into(), amount.low.into(), amount.high.into()])
        .expect('Deploy token failed');

    IERC20Dispatcher { contract_address }
}

fn deploy_router(
    class: @ContractClass, owner: ContractAddress, core: ICoreDispatcher,
    native_token: ContractAddress
) -> IISPRouterDispatcher {
    let (contract_address, _) = class
        .deploy(@array![owner.into(), core.contract_address.into(), native_token.into()])
        .expect('Deploy router failed');

    IISPRouterDispatcher { contract_address }
}

fn deploy_internal_swap_pool(
    class: @ContractClass, owner: ContractAddress, core: ICoreDispatcher,
    native_token: ContractAddress
) -> (IExtensionDispatcher, IISPDispatcher) {
    let (contract_address, _) = class
        .deploy(@array![owner.into(), core.contract_address.into(), native_token.into()])
        .expect('Deploy InternalSwapPool failed');

    (IExtensionDispatcher { contract_address }, IISPDispatcher { contract_address })
}

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher {
        contract_address: contract_address_const::<
            0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b
        >()
    }
}

fn positions() -> IPositionsDispatcher {
    IPositionsDispatcher {
        contract_address: contract_address_const::<
            0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067
        >()
    }
}

fn setup() -> (PoolKey, IISPDispatcher) {
    // Declare contract classes
    let test_token_class = declare("TestToken").unwrap().contract_class();
    let internal_swap_pool_class = declare("InternalSwapPool").unwrap().contract_class();

    // Get core contract
    let core = ekubo_core();
    
    // Use current contract as owner
    let owner = get_contract_address();
    
    // Deploy tokens to owner (the test contract itself)
    let token0 = deploy_token(test_token_class, owner, 0xffffffffffffffffffffffffffffffff);
    let token1 = deploy_token(test_token_class, owner, 0xffffffffffffffffffffffffffffffff);
    
    // Sort tokens by address (inline implementation)
    let (tokenA, tokenB) = {
        let addr0 = token0.contract_address;
        let addr1 = token1.contract_address;
        if addr0 < addr1 {
            (addr0, addr1)
        } else {
            (addr1, addr0)
        }
    };

    // Deploy InternalSwapPool once and get both interfaces
    let (internal_swap_pool_extension, internal_swap_pool_periphery) = deploy_internal_swap_pool(
        internal_swap_pool_class,
        owner,  // owner
        core, 
        tokenA   // native_token
    );

    // Create PoolKey
    let pool_key = PoolKey {
        token0: tokenA,
        token1: tokenB,
        fee: 3402823669209384705469243317362360320, // 1% fee
        tick_spacing: 999, // Tick spacing, tick spacing percentage 0.1%
        extension: internal_swap_pool_extension.contract_address
    };

    (pool_key, internal_swap_pool_periphery)
}

// Helper for u256 muldiv
fn u256_muldiv(x: u256, num: u128, denom: u128) -> u256 {
    // (x * num) / denom
    let x_lo = x.low * num;
    let x_hi = x.high * num;
    let result_lo = x_lo / denom;
    let result_hi = x_hi / denom;
    u256 { low: result_lo, high: result_hi }
}

#[test]
#[fork("mainnet")]
fn test_isp_router_swap() {
    let (pool_key, _) = setup();
    ekubo_core().initialize_pool(pool_key, Zero::zero());
    
    // Transfer tokens and mint position (your existing code)
    IERC20Dispatcher{ contract_address: pool_key.token0 }
        .transfer(positions().contract_address, 1_000_000);
    IERC20Dispatcher{ contract_address: pool_key.token1 }
        .transfer(positions().contract_address, 1_000_000);
    positions().mint_and_deposit_and_clear_both(
        pool_key,
        Bounds {
            lower: i129 { mag: 2302695, sign: true },
            upper: i129 { mag: 2302695, sign: false }
        },
        0
    );
    
    // Deploy the router
    let router_class = declare("ISPRouter").unwrap().contract_class();
    let router = deploy_router(
        router_class, 
        get_contract_address(), 
        ekubo_core(),
        pool_key.token0
    );
    
    // Prepare swap parameters
    let amount_in: u128 = 100_00;
    let token_amount = TokenAmount {
        token: pool_key.token0,
        amount: i129 { mag: amount_in, sign: false }, // Exact input (positive)
    };

    // Get current pool price
    let pool_price = ekubo_core().get_pool_price(pool_key);
    let current_sqrt_price = pool_price.sqrt_ratio;

    // Determine trade direction
    let is_token1 = pool_key.token1 == token_amount.token;
    // 5% slippage
    let slippage_numerator = if is_token1 { 95 } else { 105 };
    let slippage_denominator = 100;
    let sqrt_ratio_limit = u256_muldiv(current_sqrt_price, slippage_numerator, slippage_denominator);

    let route = RouteNode {
        pool_key,
        sqrt_ratio_limit,
        skip_ahead: 0,
    };
    let swap_data = Swap {
        route,
        token_amount,
    };

    // Approve router to spend tokens
    IERC20Dispatcher{ contract_address: pool_key.token0 }
        .approve(router.contract_address, amount_in.into());

    // Execute the swap
    router.swap(swap_data);

}
