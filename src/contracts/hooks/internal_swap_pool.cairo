// // SPDX-License-Identifier: MIT
// // Internal Swap Pool Extension for Ekubo
// // Ported from Flaunch InternalSwapPool

// use starknet::{ContractAddress, get_caller_address, get_contract_address};
// use ekubo::interfaces::core::{
//     IExtension, ICoreDispatcher, ICoreDispatcherTrait, IForwardee,
//     SwapParameters, UpdatePositionParameters
// };
// use ekubo::interfaces::mathlib::{
//     IMathLibLibraryDispatcher, IMathLibDispatcherTrait, dispatcher as mathlib
// };
// use ekubo::types::bounds::{Bounds};
// use ekubo::types::call_points::{CallPoints};
// use ekubo::types::delta::{Delta, ZeroDelta};
// use ekubo::types::i129::{i129, i129Trait};
// use ekubo::types::keys::{PoolKey, SavedBalanceKey};
// use core::num::traits::{Zero};
// use core::array::{ArrayTrait};
// use core::traits::{TryInto, Into};

// // Claimable fees structure (similar to ClaimableFees in Solidity)
// #[derive(Drop, Copy, Serde, Default)]
// pub struct ClaimableFees {
//     pub amount0: u128, // ETH equivalent
//     pub amount1: u128  // Memecoin
// }

// // Custom forward callback data for swap with fees
// #[derive(Drop, Copy, Serde)]
// pub struct SwapWithFeesForwardCallbackData {
//     pub pool_key: PoolKey,
//     pub params: SwapParameters
// }

// // Result of the swap with fees
// #[derive(Drop, Copy, Serde)]
// pub struct SwapWithFeesForwardCallbackResult {
//     pub total_delta: Delta,
//     pub fee_delta: Delta,
//     pub pool_delta: Delta
// }

// // Forward callback data enum
// #[derive(Drop, Copy, Serde)]
// pub enum ForwardCallbackData {
//     SwapWithFees: SwapWithFeesForwardCallbackData
// }

// // Forward callback result enum
// #[derive(Drop, Copy, Serde)]
// pub enum ForwardCallbackResult {
//     SwapWithFees: SwapWithFeesForwardCallbackResult
// }

// #[starknet::contract]
// pub mod InternalSwapPool {
//     use core::array::{ArrayTrait};
//     use core::num::traits::{Zero};
//     use core::traits::{TryInto, Into};
//     use ekubo::components::owned::{Owned as owned_component};
//     use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data};
//     use ekubo::components::upgradeable::{Upgradeable as upgradeable_component, IHasInterface};
//     use ekubo::interfaces::core::{
//         IExtension, SwapParameters, UpdatePositionParameters, IForwardee, ICoreDispatcher,
//         ICoreDispatcherTrait, ILocker
//     };
//     use ekubo::interfaces::mathlib::{
//         IMathLibLibraryDispatcher, IMathLibDispatcherTrait, dispatcher as mathlib
//     };
//     use ekubo::types::bounds::{Bounds};
//     use ekubo::types::call_points::{CallPoints};
//     use ekubo::types::delta::{Delta, ZeroDelta};
//     use ekubo::types::i129::{i129, i129Trait};
//     use ekubo::types::keys::{PoolKey, SavedBalanceKey};
//     use starknet::{get_contract_address, ContractAddress};
//     use super::{
//         SwapWithFeesForwardCallbackData, SwapWithFeesForwardCallbackResult,
//         ForwardCallbackData, ForwardCallbackResult, ClaimableFees
//     };

//     // Components for ownership and upgradeability
//     component!(path: owned_component, storage: owned, event: OwnedEvent);
//     #[abi(embed_v0)]
//     impl Owned = owned_component::OwnedImpl<ContractState>;
//     impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

//     component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);
//     #[abi(embed_v0)]
//     impl Upgradeable = upgradeable_component::UpgradeableImpl<ContractState>;

//     #[storage]
//     struct Storage {
//         // Core contract reference
//         core: ICoreDispatcher,
        
//         // Native token (ETH equivalent)
//         native_token: ContractAddress,
        
//         // Position manager contract reference (for fee calculation)
//         position_manager: ContractAddress,
        
//         // Fee percent (10000 = 100%)
//         fee_percent: u16,
        
//         // Accumulated fees per pool
//         pool_fees: Map<PoolKey, ClaimableFees>,
        
//         // Components for ownership and upgradeability
//         #[substorage(v0)]
//         owned: owned_component::Storage,
//         #[substorage(v0)]
//         upgradeable: upgradeable_component::Storage,
//     }

//     // Events
//     #[derive(Drop, starknet::Event)]
//     pub struct PoolFeesReceived {
//         #[key]
//         pub pool_key: PoolKey,
//         pub amount0: u128,
//         pub amount1: u128
//     }

//     #[derive(Drop, starknet::Event)]
//     pub struct PoolFeesSwapped {
//         #[key]
//         pub pool_key: PoolKey,
//         pub zero_for_one: bool,
//         pub amount0: u128,
//         pub amount1: u128
//     }

//     #[derive(starknet::Event, Drop)]
//     #[event]
//     enum Event {
//         PoolFeesReceived: PoolFeesReceived,
//         PoolFeesSwapped: PoolFeesSwapped,
//         #[flat]
//         OwnedEvent: owned_component::Event,
//         #[flat]
//         UpgradeableEvent: upgradeable_component::Event,
//     }

//     #[constructor]
//     fn constructor(
//         ref self: ContractState, 
//         owner: ContractAddress, 
//         core: ContractAddress,
//         native_token: ContractAddress,
//         position_manager: ContractAddress,
//         fee_percent: u16
//     ) {
//         // Initialize owned component
//         self.owned.initialize_owned(owner);
        
//         // Set core contract reference
//         self.core.write(ICoreDispatcher { contract_address: core });
        
//         // Set native token
//         self.native_token.write(native_token);
        
//         // Set position manager
//         self.position_manager.write(position_manager);
        
//         // Set fee percent
//         self.fee_percent.write(fee_percent);
        
//         // Set call points (which hooks to use)
//         self.core.read().set_call_points(
//             CallPoints {
//                 before_initialize_pool: false,
//                 after_initialize_pool: false,
//                 before_swap: false,  // We don't use before_swap since we can't modify delta
//                 after_swap: true,    // We use after_swap to accumulate fees
//                 before_update_position: false,
//                 after_update_position: false,
//                 before_collect_fees: false,
//                 after_collect_fees: false,
//             }
//         );
//     }

//     // Public view function to get pool fees
//     #[abi(embed_v0)]
//     fn pool_fees(self: @ContractState, pool_key: PoolKey) -> ClaimableFees {
//         self.pool_fees.read(pool_key)
//     }
    
//     // Get fee percent
//     #[abi(embed_v0)]
//     fn get_fee_percent(self: @ContractState) -> u16 {
//         self.fee_percent.read()
//     }
    
//     // Update fee percent (owner only)
//     #[abi(embed_v0)]
//     fn set_fee_percent(ref self: ContractState, fee_percent: u16) {
//         self.owned.assert_only_owner();
//         assert(fee_percent <= 10000, 'Fee percent must be <= 10000');
//         self.fee_percent.write(fee_percent);
//     }
    
//     // Update position manager (owner only)
//     #[abi(embed_v0)]
//     fn set_position_manager(ref self: ContractState, position_manager: ContractAddress) {
//         self.owned.assert_only_owner();
//         self.position_manager.write(position_manager);
//     }

//     #[generate_trait]
//     impl InternalImpl of InternalTrait {
//         // Internal function to deposit fees
//         fn _deposit_fees(
//             ref self: ContractState,
//             pool_key: PoolKey,
//             amount0: u128,
//             amount1: u128
//         ) {
//             // Skip if no fees to deposit
//             if amount0.is_zero() && amount1.is_zero() {
//                 return;
//             }
            
//             // Update stored fees
//             let mut current_fees = self.pool_fees.read(pool_key);
//             current_fees.amount0 += amount0;
//             current_fees.amount1 += amount1;
//             self.pool_fees.write(pool_key, current_fees);
            
//             // Emit event
//             self.emit(PoolFeesReceived { pool_key, amount0, amount1 });
//         }
        
//         // Determine if a token is the native token
//         fn _is_native_token(self: @ContractState, token: ContractAddress) -> bool {
//             token == self.native_token.read()
//         }
        
//         // Get whether native token is currency0 in pool
//         fn _native_is_zero(self: @ContractState, pool_key: PoolKey) -> bool {
//             self._is_native_token(pool_key.token0)
//         }
        
//         // Calculate fee amount from delta
//         fn _calculate_fee_amount(self: @ContractState, amount: u128) -> u128 {
//             amount * self.fee_percent.read().into() / 10000
//         }
//     }

//     #[abi(embed_v0)]
//     impl ExtensionImpl of IExtension<ContractState> {
//         fn before_initialize_pool(
//             ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
//         ) {
//             // Not used
//         }

//         fn after_initialize_pool(
//             ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
//         ) {
//             // Not used
//         }

//         fn before_swap(
//             ref self: ContractState,
//             caller: ContractAddress,
//             pool_key: PoolKey,
//             params: SwapParameters
//         ) {
//             // Not used - we handle swaps through forwarded pattern instead
//         }

//         // After swap, accumulate fees - for regular swaps not through our extension
//         fn after_swap(
//             ref self: ContractState,
//             caller: ContractAddress,
//             pool_key: PoolKey,
//             params: SwapParameters,
//             delta: Delta
//         ) {
//             // Skip if caller is our position manager (to avoid double counting)
//             if caller == self.position_manager.read() || caller == get_contract_address() {
//                 return;
//             }
            
//             // Calculate and accumulate fees
//             let native_is_zero = self._native_is_zero(pool_key);
            
//             // Calculate fee amount based on swap direction
//             if params.is_token1 == native_is_zero {
//                 // Buying memecoin with native - fee in memecoin
//                 let fee_amount = if delta.amount1.is_negative() {
//                     self._calculate_fee_amount(delta.amount1.mag)
//                 } else {
//                     0
//                 };
                
//                 if fee_amount > 0 {
//                     self._deposit_fees(pool_key, 0, fee_amount);
//                 }
//             } else {
//                 // Selling memecoin for native - fee in native
//                 let fee_amount = if delta.amount0.is_negative() {
//                     self._calculate_fee_amount(delta.amount0.mag)
//                 } else {
//                     0
//                 };
                
//                 if fee_amount > 0 {
//                     self._deposit_fees(pool_key, fee_amount, 0);
//                 }
//             }
//         }

//         fn before_update_position(
//             ref self: ContractState,
//             caller: ContractAddress,
//             pool_key: PoolKey,
//             params: UpdatePositionParameters
//         ) {
//             // Not used
//         }

//         fn after_update_position(
//             ref self: ContractState,
//             caller: ContractAddress,
//             pool_key: PoolKey,
//             params: UpdatePositionParameters,
//             delta: Delta
//         ) {
//             // Not used
//         }

//         fn before_collect_fees(
//             ref self: ContractState,
//             caller: ContractAddress,
//             pool_key: PoolKey,
//             salt: felt252,
//             bounds: Bounds
//         ) {
//             // Not used
//         }
        
//         fn after_collect_fees(
//             ref self: ContractState,
//             caller: ContractAddress,
//             pool_key: PoolKey,
//             salt: felt252,
//             bounds: Bounds,
//             delta: Delta
//         ) {
//             // Not used
//         }
//     }

//     #[abi(embed_v0)]
//     impl ForwardeeImpl of IForwardee<ContractState> {
//         fn forwarded(
//             ref self: ContractState, 
//             original_locker: ContractAddress, 
//             id: u32, 
//             data: Span<felt252>
//         ) -> Span<felt252> {
//             let core = self.core.read();
            
//             let result: ForwardCallbackResult = match consume_callback_data::<ForwardCallbackData>(core, data) {
//                 ForwardCallbackData::SwapWithFees(params) => {
//                     let SwapWithFeesForwardCallbackData { pool_key, params: swap_params } = params;
                    
//                     // Execute the internal swap logic
//                     let (fee_delta, pool_delta) = self._internal_swap(original_locker, pool_key, swap_params);
                    
//                     // Combine deltas for total swap
//                     let total_delta = Delta {
//                         amount0: fee_delta.amount0 + pool_delta.amount0,
//                         amount1: fee_delta.amount1 + pool_delta.amount1
//                     };
                    
//                     ForwardCallbackResult::SwapWithFees(
//                         SwapWithFeesForwardCallbackResult {
//                             total_delta,
//                             fee_delta,
//                             pool_delta
//                         }
//                     )
//                 }
//             };
            
//             // Serialize and return the result
//             let mut result_data = array![];
//             Serde::serialize(@result, ref result_data);
//             result_data.span()
//         }
//     }

//     #[generate_trait]
//     impl InternalSwapImpl of InternalSwapTrait {
//         // Process a swap using accumulated fees before passing to the pool
//         fn _internal_swap(
//             ref self: ContractState,
//             original_locker: ContractAddress,
//             pool_key: PoolKey,
//             params: SwapParameters
//         ) -> (Delta, Delta) {
//             let core = self.core.read();
//             let math = mathlib();
            
//             // Get accumulated fees
//             let mut pending_pool_fees = self.pool_fees.read(pool_key);
            
//             // Check if we have any fees to use
//             if pending_pool_fees.amount1.is_zero() {
//                 // No fees to use, just process the swap normally
//                 let pool_delta = core.swap(pool_key, params);
//                 return (Delta::zero(), pool_delta);
//             }
            
//             // Check if we're buying memecoin with native token
//             let native_is_zero = self._native_is_zero(pool_key);
//             if native_is_zero != params.is_token1 {
//                 // We're not buying memecoin with native, just process normally
//                 let pool_delta = core.swap(pool_key, params);
//                 return (Delta::zero(), pool_delta);
//             }
            
//             // Get current pool price
//             let price = core.get_pool_price(pool_key);
            
//             // Calculate how much we can process internally
//             let (eth_in, token_out) = if params.amount.is_negative() {
//                 // Exact output swap - user wants specific amount of memecoin
                
//                 // Limited by available fees
//                 let available_amount = if params.amount.mag > pending_pool_fees.amount1 {
//                     pending_pool_fees.amount1
//                 } else {
//                     params.amount.mag
//                 };
                
//                 // Calculate the ETH input required for this memecoin output
//                 let eth_in = if available_amount.is_zero() {
//                     0
//                 } else {
//                     // Use math library to calculate equivalent ETH amount
//                     let sqrt_ratio_lower = if params.is_token1 {
//                         price.sqrt_ratio
//                     } else {
//                         params.sqrt_ratio_limit
//                     };
                    
//                     let sqrt_ratio_upper = if params.is_token1 {
//                         params.sqrt_ratio_limit
//                     } else {
//                         price.sqrt_ratio
//                     };
                    
//                     // Use math library to calculate amount0 for this amount1
//                     math.amount0_delta(
//                         sqrt_ratio_lower,
//                         sqrt_ratio_upper,
//                         available_amount,
//                         true // round up for exact output
//                     )
//                 };
                
//                 (eth_in, available_amount)
//             } else {
//                 // Exact input swap - user is spending specific amount of ETH
                
//                 // Use Math library to simulate the swap
//                 let sqrt_ratio_lower = if params.is_token1 {
//                     params.sqrt_ratio_limit
//                 } else {
//                     price.sqrt_ratio
//                 };
                
//                 let sqrt_ratio_upper = if params.is_token1 {
//                     price.sqrt_ratio
//                 } else {
//                     params.sqrt_ratio_limit
//                 };
                
//                 // Calculate the memecoin output for the ETH input
//                 let token_out = math.amount1_delta(
//                     sqrt_ratio_lower,
//                     sqrt_ratio_upper,
//                     params.amount.mag,
//                     false // round down for exact input
//                 );
                
//                 // Limit by available fees
//                 if token_out > pending_pool_fees.amount1 {
//                     // If we can't fulfill entire amount, calculate proportional ETH input
//                     let eth_in = (pending_pool_fees.amount1 * params.amount.mag) / token_out;
//                     (eth_in, pending_pool_fees.amount1)
//                 } else {
//                     (params.amount.mag, token_out)
//                 }
//             };
            
//             // If we couldn't process anything internally, just do normal swap
//             if eth_in.is_zero() || token_out.is_zero() {
//                 let pool_delta = core.swap(pool_key, params);
//                 return (Delta::zero(), pool_delta);
//             }
            
//             // Update the accumulated fees
//             pending_pool_fees.amount0 += eth_in;
//             pending_pool_fees.amount1 -= token_out;
//             self.pool_fees.write(pool_key, pending_pool_fees);
            
//             // Process the fee portion of the swap
//             let fee_delta = if native_is_zero {
//                 // Native is token0, memecoin is token1
//                 // Take ETH, give memecoin
                
//                 // Take ETH from user by saving it
//                 core.save(SavedBalanceKey {
//                     owner: get_contract_address(),
//                     token: pool_key.token0,
//                     salt: 0
//                 }, eth_in);
                
//                 // Give memecoin to user
//                 core.withdraw(
//                     token_address: pool_key.token1,
//                     recipient: original_locker,
//                     amount: token_out
//                 );
                
//                 Delta {
//                     amount0: i129 { mag: eth_in, sign: true },  // Positive for ETH taken (from user perspective)
//                     amount1: i129 { mag: token_out, sign: false } // Negative for memecoin given
//                 }
//             } else {
//                 // Native is token1, memecoin is token0
//                 // Take ETH, give memecoin
                
//                 // Take ETH from user
//                 core.save(SavedBalanceKey {
//                     owner: get_contract_address(),
//                     token: pool_key.token1,
//                     salt: 0
//                 }, eth_in);
                
//                 // Give memecoin to user
//                 core.withdraw(
//                     token_address: pool_key.token0,
//                     recipient: original_locker,
//                     amount: token_out
//                 );
                
//                 Delta {
//                     amount0: i129 { mag: token_out, sign: false }, // Negative for memecoin given
//                     amount1: i129 { mag: eth_in, sign: true }    // Positive for ETH taken
//                 }
//             };
            
//             // Emit event for internal swap
//             self.emit(PoolFeesSwapped { 
//                 pool_key, 
//                 zero_for_one: params.is_token1, 
//                 amount0: if native_is_zero { eth_in } else { token_out },
//                 amount1: if native_is_zero { token_out } else { eth_in }
//             });
            
//             // Calculate remaining swap amount
//             let remaining_params = if params.amount.is_negative() {
//                 // For exact output, reduce the output amount
//                 let remaining_amount = params.amount.mag - token_out;
                
//                 if remaining_amount.is_zero() {
//                     // We fulfilled the entire swap internally
//                     return (fee_delta, Delta::zero());
//                 }
                
//                 // Create new params with adjusted amount
//                 SwapParameters {
//                     amount: i129 { mag: remaining_amount, sign: true },
//                     is_token1: params.is_token1,
//                     sqrt_ratio_limit: params.sqrt_ratio_limit,
//                     skip_ahead: params.skip_ahead
//                 }
//             } else {
//                 // For exact input, reduce the input amount
//                 let remaining_amount = params.amount.mag - eth_in;
                
//                 if remaining_amount.is_zero() {
//                     // We fulfilled the entire swap internally
//                     return (fee_delta, Delta::zero());
//                 }
                
//                 // Create new params with adjusted amount
//                 SwapParameters {
//                     amount: i129 { mag: remaining_amount, sign: false },
//                     is_token1: params.is_token1,
//                     sqrt_ratio_limit: params.sqrt_ratio_limit,
//                     skip_ahead: params.skip_ahead
//                 }
//             };
            
//             // Process the remaining swap through the pool
//             let pool_delta = core.swap(pool_key, remaining_params);
            
//             (fee_delta, pool_delta)
//         }
//     }

//     #[abi(embed_v0)]
//     impl HasInterface of IHasInterface<ContractState> {
//         fn get_primary_interface_id(self: @ContractState) -> felt252 {
//             return selector!("relaunch::extensions::internal_swap_pool::InternalSwapPool");
//         }
//     }
// }