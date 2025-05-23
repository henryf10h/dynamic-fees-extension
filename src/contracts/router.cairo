// SPDX-License-Identifier: MIT
#[starknet::contract]
pub mod ISPRouter {
    use core::array::{ArrayTrait};
    use core::traits::Into;
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::interfaces::core::{
        ICoreDispatcher, ICoreDispatcherTrait, SwapParameters, IForwardeeDispatcher, ILocker
    };
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::delta::{Delta};
    use ekubo::types::i129::{i129};
    use ekubo::types::keys::{PoolKey};
    use starknet::{get_contract_address, get_caller_address, ContractAddress};
    use starknet::storage::{
        StoragePointerWriteAccess, StorageMapWriteAccess, StorageMapReadAccess,
        StoragePointerReadAccess, Map
    };

    // Import ISP types from the correct module path
    use relaunch::contracts::internal_swap_pool::{ISPSwapData, ISPSwapResult, ClaimableFees};
    
    // Define the position manager interface here since it's internal to the position_manager module
    #[starknet::interface]
    pub trait IPositionManagerISP<TContractState> {
        fn get_pool_fees(self: @TContractState, pool_key: PoolKey) -> ClaimableFees;
        fn can_use_prefill(
            self: @TContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> bool;
        fn accumulate_fees(
            ref self: TContractState,
            pool_key: PoolKey,
            token: ContractAddress,
            amount: u128
        );
        fn get_native_token(self: @TContractState) -> ContractAddress;
        fn execute_isp_swap(
            ref self: TContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            user: ContractAddress,
            max_fee_amount: u128
        ) -> ISPSwapResult;
    }

    #[abi(embed_v0)]
    impl Clear = ekubo::components::clear::ClearImpl<ContractState>;

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        native_token: ContractAddress,
        // Track which extensions are ISP-enabled
        isp_extensions: Map<ContractAddress, bool>,
        // Fee percentage for non-ISP swaps (basis points)
        fee_percentage: u128,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        core: ICoreDispatcher,
        native_token: ContractAddress,
        fee_percentage: u128,
    ) {
        self.initialize_owned(owner);
        self.core.write(core);
        self.native_token.write(native_token);
        self.fee_percentage.write(fee_percentage); // e.g., 30 = 0.3%
    }

    #[derive(Drop, starknet::Event)]
    pub struct SwapRouted {
        #[key]
        pub pool_key: PoolKey,
        #[key]
        pub user: ContractAddress,
        pub used_isp: bool,
        pub prefill_amount: u128,
        pub total_output: u128,
        pub fee_collected: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ISPExtensionRegistered {
        #[key]
        pub extension: ContractAddress,
        pub enabled: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeesAccumulated {
        #[key]
        pub pool_key: PoolKey,
        pub token: ContractAddress,
        pub amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        SwapRouted: SwapRouted,
        ISPExtensionRegistered: ISPExtensionRegistered,
        FeesAccumulated: FeesAccumulated,
        #[flat]
        OwnedEvent: owned_component::Event,
    }

    /// Interface for ISP Router
    #[starknet::interface]
    pub trait IISPRouter<TContractState> {
        fn swap(
            ref self: TContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            token_in: ContractAddress,
            amount_in_max: u128,
            amount_out_min: u128,
            deadline: u64
        ) -> Delta;

        fn register_isp_extension(
            ref self: TContractState, 
            extension: ContractAddress, 
            enabled: bool
        );

        fn preview_isp_swap(
            self: @TContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> (bool, ClaimableFees, u128);

        fn get_pool_fees(self: @TContractState, pool_key: PoolKey) -> ClaimableFees;
    }

    #[abi(embed_v0)]
    impl ISPRouterImpl of IISPRouter<ContractState> {
        /// Main swap function - automatically uses ISP if available and beneficial
        fn swap(
            ref self: ContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            token_in: ContractAddress,
            amount_in_max: u128,
            amount_out_min: u128,
            deadline: u64
        ) -> Delta {
            // Check deadline
            assert(starknet::get_block_timestamp() <= deadline, 'Deadline exceeded');

            let user = get_caller_address();
            
            // Check if pool extension supports ISP
            let supports_isp = self.isp_extensions.read(pool_key.extension);
            
            if supports_isp {
                // Try ISP swap
                let isp_result = self._execute_isp_swap(pool_key, params, user, amount_in_max);
                
                // Check if ISP was actually used (prefill occurred)
                if isp_result.prefill_amount > 0 {
                    self.emit(SwapRouted {
                        pool_key,
                        user,
                        used_isp: true,
                        prefill_amount: isp_result.prefill_amount,
                        total_output: if params.is_token1 { 
                            isp_result.total_delta.amount1.mag 
                        } else { 
                            isp_result.total_delta.amount0.mag 
                        },
                        fee_collected: isp_result.fee_collected,
                    });
                    
                    return isp_result.total_delta;
                }
            }

            // Fall back to regular swap with fee collection
            let result = self._execute_regular_swap_with_fees(
                pool_key, 
                params, 
                token_in, 
                amount_in_max, 
                amount_out_min, 
                user
            );
            
            self.emit(SwapRouted {
                pool_key,
                user,
                used_isp: false,
                prefill_amount: 0,
                total_output: if params.is_token1 { 
                    result.amount1.mag 
                } else { 
                    result.amount0.mag 
                },
                fee_collected: 0, // Fee collection handled separately for regular swaps
            });

            result
        }

        /// Register an extension as ISP-enabled
        fn register_isp_extension(ref self: ContractState, extension: ContractAddress, enabled: bool) {
            self.initialize_owned(get_caller_address());//todo: check the owner here!
            self.isp_extensions.write(extension, enabled);
            
            self.emit(ISPExtensionRegistered { extension, enabled });
        }

        /// Check if pool supports ISP and preview potential prefill
        fn preview_isp_swap(
            self: @ContractState,
            pool_key: PoolKey,
            params: SwapParameters
        ) -> (bool, ClaimableFees, u128) {
            let supports_isp = self.isp_extensions.read(pool_key.extension);
            
            if !supports_isp {
                return (false, ClaimableFees { amount0: 0, amount1: 0 }, 0);
            }

            // Query the ISP extension for available fees
            let isp_manager = IPositionManagerISPDispatcher { contract_address: pool_key.extension };
            let available_fees = IPositionManagerISPDispatcherTrait::get_pool_fees(isp_manager, pool_key);
            
            // Check if this swap can use prefill
            let can_prefill = IPositionManagerISPDispatcherTrait::can_use_prefill(isp_manager, pool_key, params);
            
            let potential_prefill = if can_prefill {
                // Simple estimation - in production, calculate more precisely
                if params.amount.sign {
                    core::cmp::min(available_fees.amount1, params.amount.mag)
                } else {
                    core::cmp::min(available_fees.amount1, params.amount.mag)
                }
            } else {
                0
            };

            (supports_isp, available_fees, potential_prefill)
        }

        /// Get accumulated fees for a pool
        fn get_pool_fees(self: @ContractState, pool_key: PoolKey) -> ClaimableFees {
            let supports_isp = self.isp_extensions.read(pool_key.extension);
            
            if supports_isp {
                let isp_manager = IPositionManagerISPDispatcher { contract_address: pool_key.extension };
                IPositionManagerISPDispatcherTrait::get_pool_fees(isp_manager, pool_key)
            } else {
                ClaimableFees { amount0: 0, amount1: 0 }
            }
        }
    }

    // Simple locker implementation for handling swaps
    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            // This would handle regular swaps if needed
            // For now, most logic is in the main functions
            array![].span()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Execute ISP swap using the lock-forward pattern
        fn _execute_isp_swap(
            ref self: ContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            user: ContractAddress,
            max_amount_in: u128
        ) -> ISPSwapResult {
            let core = self.core.read();
            let native_token = self.native_token.read();
            
            // For ETH → Token swaps, collect ETH from user first
            let is_eth_for_token = self._is_eth_for_token_swap(pool_key, params, native_token);
            
            if is_eth_for_token {
                // Take ETH from user for potential fee payment
                // The ISP will determine actual fee amount
                let eth_token = IERC20Dispatcher { contract_address: native_token };
                
                // Transfer ETH to this router first
                let amount_u256: u256 = max_amount_in.into();
                eth_token.transferFrom(user, get_contract_address(), amount_u256);
                
                // Pay ETH to core for the ISP extension to use
                eth_token.approve(core.contract_address, amount_u256);
                core.pay(native_token);
            }

            // Prepare ISP data
            let isp_data = ISPSwapData {
                pool_key,
                params,
                user,
                max_fee_amount: max_amount_in, // Max fee user is willing to pay
            };

            // Forward to ISP extension using lock-forward pattern
            let forwardee = IForwardeeDispatcher { contract_address: pool_key.extension };
            
            // Serialize the ISP data
            let mut serialized_data = array![];
            core::serde::Serde::serialize(@isp_data, ref serialized_data);
            
            // Forward the call and get result
            let result_data = core.forward(forwardee, serialized_data.span());
            
            // Deserialize result
            let mut result_span = result_data;
            let result: ISPSwapResult = core::serde::Serde::deserialize(ref result_span).unwrap();
            
            result
        }

        /// Execute regular swap with fee collection
        fn _execute_regular_swap_with_fees(
            ref self: ContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            token_in: ContractAddress,
            amount_in_max: u128,
            amount_out_min: u128,
            user: ContractAddress
        ) -> Delta {
            let core = self.core.read();
            
            // Calculate fee to collect
            let fee_amount = (amount_in_max * self.fee_percentage.read()) / 10000;
            let swap_amount = amount_in_max - fee_amount;
            
            // Collect tokens from user
            let token_in_contract = IERC20Dispatcher { contract_address: token_in };
            let amount_in_u256: u256 = amount_in_max.into();
            token_in_contract.transferFrom(user, get_contract_address(), amount_in_u256);
            
            // Pay swap amount to core
            let swap_amount_u256: u256 = swap_amount.into();
            token_in_contract.approve(core.contract_address, swap_amount_u256);
            core.pay(token_in);
            
            // Execute the swap
            let adjusted_params = SwapParameters {
                amount: i129 { mag: swap_amount, sign: params.amount.sign },
                is_token1: params.is_token1,
                sqrt_ratio_limit: params.sqrt_ratio_limit,
                skip_ahead: params.skip_ahead,
            };
            
            let delta = core.swap(pool_key, adjusted_params);
            
            // Withdraw output tokens to user
            let token_out = if token_in == pool_key.token0 { pool_key.token1 } else { pool_key.token0 };
            let output_amount = if params.is_token1 { delta.amount1.mag } else { delta.amount0.mag };
            
            assert(output_amount >= amount_out_min, 'Insufficient output');
            
            core.withdraw(token_out, user, output_amount);
            
            // Accumulate fees if pool supports ISP
            if self.isp_extensions.read(pool_key.extension) && fee_amount > 0 {
                let isp_manager = IPositionManagerISPDispatcher { contract_address: pool_key.extension };
                
                // Transfer fee to ISP manager through core
                let fee_amount_u256: u256 = fee_amount.into();
                token_in_contract.approve(pool_key.extension, fee_amount_u256);
                
                // Tell ISP manager to accumulate the fees
                IPositionManagerISPDispatcherTrait::accumulate_fees(isp_manager, pool_key, token_in, fee_amount);
                
                self.emit(FeesAccumulated { 
                    pool_key, 
                    token: token_in, 
                    amount: fee_amount 
                });
            }
            
            delta
        }

        /// Check if this is an ETH for token swap
        fn _is_eth_for_token_swap(
            self: @ContractState,
            pool_key: PoolKey,
            params: SwapParameters,
            native_token: ContractAddress
        ) -> bool {
            let native_is_token0 = native_token == pool_key.token0;
            (native_is_token0 && !params.is_token1) || (!native_is_token0 && params.is_token1)
        }
    }
}