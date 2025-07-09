use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher, SwapParameters};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::types::keys::{PoolKey};
use ekubo::types::bounds::{Bounds};
use ekubo::types::i129::{i129};
use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
use core::num::traits::{Zero};
use relaunch::interfaces::Irouter::{IISPRouterDispatcher, IISPRouterDispatcherTrait};
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

fn deploy_position_manager_extension(
    class: @ContractClass, owner: ContractAddress, core: ICoreDispatcher,
    native_token: ContractAddress
) -> IExtensionDispatcher {
    let (contract_address, _) = class
        .deploy(@array![owner.into(), core.contract_address.into(), native_token.into()])
        .expect('Deploy position manager failed');

    IExtensionDispatcher { contract_address }
}

fn deploy_position_manager_periphery(
    class: @ContractClass, owner: ContractAddress, core: ICoreDispatcher,
    native_token: ContractAddress
) -> IISPDispatcher {
    let (contract_address, _) = class
        .deploy(@array![owner.into(), core.contract_address.into(), native_token.into()])
        .expect('Deploy periphery failed');

    IISPDispatcher { contract_address }
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
    let position_manager_class = declare("PositionManager").unwrap().contract_class();

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
    
    // Deploy PositionManager using owner for both roles
    let position_manager_extension = deploy_position_manager_extension(
        position_manager_class, 
        owner,  // owner
        core, 
        tokenA   // native_token
    );
    
    let position_manager_periphery = deploy_position_manager_periphery(
        position_manager_class, 
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
        extension: position_manager_extension.contract_address
    };
    
    (pool_key, position_manager_periphery)
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
    let swap_params = SwapParameters {
        amount: i129 { mag: amount_in, sign: false }, // Exact input (positive)
        is_token1: false, // Swapping token0 -> token1
        sqrt_ratio_limit: 0, // No price limit
        skip_ahead: 0, // No skip ahead
        
    };
    
    // Approve router to spend tokens
    IERC20Dispatcher{ contract_address: pool_key.token0 }
        .approve(router.contract_address, amount_in.into());
    
    // Execute the swap
    let result = router.swap(
        pool_key,
        swap_params,
        pool_key.token0, // token_in
        amount_in
    );
    
    // You can now test the result
    assert!(result.output_amount > 0, "Swap should produce output");
}

//todo: need to add mathlib from ekubo to do tick->sqrt_ratio conversion
//todo: need to check how swap parameters are being passed 
//understand the shared_locker functions
