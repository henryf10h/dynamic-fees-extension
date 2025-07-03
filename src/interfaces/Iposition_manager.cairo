// SPDX-License-Identifier: MIT

use starknet::ContractAddress;
    
    // Public interface for ISP functionality
    #[starknet::interface]
    pub trait IPositionManagerISP<TContractState> {
        fn get_native_token(self: @TContractState) -> ContractAddress;
    }
