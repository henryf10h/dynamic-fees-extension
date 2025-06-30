// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts for Cairo ^1.0.0

#[starknet::contract]
mod Memecoin {
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::governance::votes::VotesComponent;
    use openzeppelin::token::erc20::{ERC20Component, DefaultConfig};
    use openzeppelin::utils::cryptography::nonces::NoncesComponent;
    use openzeppelin::utils::cryptography::snip12::SNIP12Metadata;
    use starknet::{ContractAddress, get_caller_address, event};
    use core::num::traits::{Zero};
    // use core::zeroable;
    use core::traits::Into;
    use relaunch::interfaces::Imemecoin::IMeme;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: NoncesComponent, storage: nonces, event: NoncesEvent);
    component!(path: VotesComponent, storage: votes, event: VotesEvent);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    // External
    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20MixinImpl<ContractState>;
    #[abi(embed_v0)]
    impl NoncesImpl = NoncesComponent::NoncesImpl<ContractState>;
    #[abi(embed_v0)]
    impl VotesImpl = VotesComponent::VotesImpl<ContractState>;
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;

    // Internal
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
    impl VotesInternalImpl = VotesComponent::InternalImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        nonces: NoncesComponent::Storage,
        #[substorage(v0)]
        votes: VotesComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        // Add custom storage for Memecoin functionality
        relaunch_contract: ContractAddress,  // Address of the relaunch contract
        token_uri: ByteArray,                 // URI for token metadata
        is_initialized: bool,               // To prevent multiple initializations
        token_id: u256,                     // Token ID in the relaunch contract
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        NoncesEvent: NoncesComponent::Event,
        #[flat]
        VotesEvent: VotesComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        // Custom events
        MetadataUpdated: MetadataUpdated,
        Initialized: Initialized,
    }

    #[derive(Drop, starknet::Event)]
    struct MetadataUpdated {
        #[key]
        name: ByteArray,
        #[key]
        symbol: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct Initialized {
        #[key]
        name: ByteArray,
        #[key]
        symbol: ByteArray,
        #[key]
        token_uri: ByteArray,
        #[key]
        relaunch: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        // Constructor intentionally left minimal
        // We'll use initialize instead, following the pattern from Memecoin.sol
        self.is_initialized.write(false);
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        // Internal function to check if caller is the relaunch contract
        fn assert_only_relaunch(self: @ContractState) {
            let caller = get_caller_address();
            let relaunch = self.relaunch_contract.read();
            assert(caller == relaunch, 'Caller is not relaunch contract');
        }
    }

    #[abi(embed_v0)]
    impl MemeImpl of IMeme<ContractState> {
        // Initializes the token - can only be called once
        fn initialize(
            ref self: ContractState, 
            name: ByteArray, 
            symbol: ByteArray, 
            token_uri: ByteArray
        ) {
            // Ensure this can only be called once
            assert(!self.is_initialized.read(), 'Already initialized');
            
            // Set the relaunch contract as the caller
            let relaunch = get_caller_address();
            self.relaunch_contract.write(relaunch);
            
            // Initialize the ERC20 component
            self.erc20.initializer(name, symbol);
            
            // Store the token URI
            self.token_uri.write(token_uri);
            
            // Mark as initialized
            self.is_initialized.write(true);
            
            // Emit initialization event
            // self.emit(Initialized{ 
            //     name, 
            //     symbol, 
            //     token_uri, 
            //     relaunch
            // });
        }

        // Set token ID (used by relaunch contract)
        fn set_token_id(ref self: ContractState, token_id: u256) {
            self.assert_only_relaunch();
            self.token_id.write(token_id);
        }

        // Mint function - only callable by relaunch contract
        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            // Check that caller is relaunch contract
            self.assert_only_relaunch();
            
            // Check that recipient is not zero address
            assert(!to.is_zero(), 'MintAddressIsZero');
            
            // Mint tokens using the internal function
            self.erc20.mint(to, amount);
            
            // Emit transfer event
            // self.emit(ERC20Event::Transfer {
            //     from: zero_address(),
            //     to,
            //     value: amount,
            // });
        }

        // Burn function - can be called by any token holder
        fn burn(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            self.erc20.burn(caller, amount);
        }

        // BurnFrom function - can be called by approved spenders
        fn burn_from(ref self: ContractState, account: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            
            // Spend allowance
            self.erc20._spend_allowance(account, caller, amount);
            
            // Burn tokens
            self.erc20.burn(account, amount);
        }

        // Update token metadata - only callable by relaunch contract
        fn set_metadata(ref self: ContractState, name: ByteArray, symbol: ByteArray) {
            // Check that caller is relaunch contract
            self.assert_only_relaunch();
            
            // Update name and symbol
            self.erc20.ERC20_name.write(name);
            self.erc20.ERC20_symbol.write(symbol);
            
            // Emit event
            // self.emit(MetadataUpdated { name, symbol });
        }

        // Get the token URI
        fn token_uri(self: @ContractState) -> ByteArray {
            self.token_uri.read()
        }

        // Get the relaunch contract address
        fn relaunch(self: @ContractState) -> ContractAddress {
            self.relaunch_contract.read()
        }

        // Get token ID
        fn token_id(self: @ContractState) -> u256 {
            self.token_id.read()
        }

        // Get creator - this would need to query the relaunch contract
        // We'll add a placeholder for now
        fn creator(self: @ContractState) -> ContractAddress {
            // In Solidity, this calls relaunch.ownerOf(tokenId)
            // For now, return the relaunch contract address
            // This would need to be updated once you have a relaunch contract
            self.relaunch_contract.read()
        }

        // Get treasury - this would need to query the relaunch contract
        // We'll add a placeholder for now
        // fn treasury(self: @ContractState) -> ContractAddress {
        //     // In Solidity, this calls relaunch.memecoinTreasury(tokenId)
        //     // For now, return zero address
        //     // This would need to be updated once you have a relaunch contract
        //     get_caller_address() //todo: change this to the treasury address
        // }
    }

    impl ERC20HooksImpl of ERC20Component::ERC20HooksTrait<ContractState> {
        fn after_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) {
            let mut contract_state = self.get_contract_mut();
            contract_state.votes.transfer_voting_units(from, recipient, amount);
        }
    }

    //
    // SNIP12 Metadata
    //
    
    impl SNIP12MetadataImpl of SNIP12Metadata {
        fn name() -> felt252 {
            'relaunch'
        }

        fn version() -> felt252 {
            'v1'
        }
    }
}

//todo: change this to the treasury address.
//No treasury contracts yet. Coming soon.

