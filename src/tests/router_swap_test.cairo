use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher};
use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
use relaunch::interfaces::Irouter::{IISPRouterDispatcher, IISPRouterDispatcherTrait};
use relaunch::interfaces::Iposition_manager::{
    IPositionManagerISPDispatcher, IPositionManagerISPDispatcherTrait,
};
use relaunch::contracts::test_token::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    declare, DeclareResultTrait, ContractClassTrait, ContractClass, cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp_global, CheatSpan,
};
use starknet::{get_block_timestamp, contract_address_const, ContractAddress};

// I need a router dispatcher 
// I need a erc20 dispatcher
// I need ekubo core dispatcher
// I need a position manager dispatcher

// deploy token, core, positions, router
// router needs owner, core and native_token and returns IISRouterDispatcher

// deploy position manager contract as an extension and as a periphery (isp interface)
// position manager needs owner, core, native_token and returns IPositionsDispatcher

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
// todo: pass the isp interface here as a dispatcher
fn deploy_position_manager_periphery(
    class: @ContractClass, owner: ContractAddress, core: ICoreDispatcher,
    native_token: ContractAddress
) -> IPositionsDispatcher {
    let (contract_address, _) = class
        .deploy(@array![owner.into(), core.contract_address.into(), native_token.into()])
        .expect('Deploy periphery failed');

    IPositionsDispatcher { contract_address }
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