// SPDX-License-Identifier: MIT

use starknet::ContractAddress;
use starknet::ClassHash;

#[starknet::interface]
pub trait IRelaunch<TContractState> {
    // View functions
    fn memecoin_contract(self: @TContractState, token_id: u256) -> ContractAddress;
    fn memecoin_treasury(self: @TContractState, token_id: u256) -> ContractAddress;
    fn memecoin_to_token_id(self: @TContractState, memecoin: ContractAddress) -> u256;
    fn last_token_id(self: @TContractState) -> u256;
    fn meme_factory(self: @TContractState) -> ClassHash;
    fn token_uri(self: @TContractState, token_id: u256) -> ByteArray;
    
    // Core functions
    fn create_memecoin(
        ref self: TContractState,
        name: ByteArray,
        symbol: ByteArray,
        token_uri: ByteArray,
        initial_supply: u256,
        treasury: ContractAddress
    ) -> (ContractAddress, u256);
    
    // Admin functions
    fn set_meme_factory(ref self: TContractState, meme_factory: ClassHash);
    fn set_memecoin_treasury(ref self: TContractState, token_id: u256, treasury: ContractAddress);
    fn set_base_uri(ref self: TContractState, base_uri: ByteArray);
    
    // Role management
    fn grant_deployer_role(ref self: TContractState, account: ContractAddress);
    fn revoke_deployer_role(ref self: TContractState, account: ContractAddress);
    fn has_deployer_role(self: @TContractState, account: ContractAddress) -> bool;
}