use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use ekubo::types::keys::{PoolKey};
use relaunch::interfaces::Irouter::{IISPRouterDispatcher, IISPRouterDispatcherTrait};
use relaunch::interfaces::Iisp::{IISPDispatcher, IISPDispatcherTrait};
use relaunch::contracts::test_token::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    declare, DeclareResultTrait, ContractClassTrait, ContractClass, cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp_global, CheatSpan,
};
use starknet::{get_block_timestamp, contract_address_const, ContractAddress, get_contract_address};

// I need a router dispatcher 
// I need a erc20 dispatcher
// I need ekubo core dispatcher
// I need a position manager dispatcher

// deploy token, core, positions, router
// router needs owner, core and native_token and returns IISRouterDispatcher

// deploy position manager contract as an extension and as a periphery (isp interface)
// position manager needs owner, core, native_token and returns IISPDispatcher

// define a setup function
// define a swap test using the isp's router

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
        fee: 0x68db8bac710cb4000000000000000, // 0.01% fee
        tick_spacing: 999, // Tick spacing
        extension: position_manager_extension.contract_address
    };
    
    (pool_key, position_manager_periphery)
}

#[test]
#[fork("mainnet")]
fn test_isp_router_swap() {}
