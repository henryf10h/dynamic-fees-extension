// SPDX-License-Identifier: MIT

use starknet::ContractAddress;

#[starknet::interface]
pub trait IMeme<TState> {
    fn initialize(
        ref self: TState,
        name: ByteArray,
        symbol: ByteArray,
        token_uri: ByteArray
    );
    fn set_token_id(ref self: TState, token_id: u256);
    fn mint(ref self: TState, to: ContractAddress, amount: u256);
    fn burn(ref self: TState, amount: u256);
    fn burn_from(ref self: TState, account: ContractAddress, amount: u256);
    fn set_metadata(ref self: TState, name: ByteArray, symbol: ByteArray);
    fn token_uri(self: @TState) -> ByteArray;
    fn relaunch(self: @TState) -> ContractAddress;
    fn token_id(self: @TState) -> u256;
    fn creator(self: @TState) -> ContractAddress;
    fn treasury(self: @TState) -> ContractAddress;
}