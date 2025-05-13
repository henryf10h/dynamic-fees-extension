// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts for Cairo ^1.0.0

#[starknet::contract]
mod Relaunch {
    use starknet::storage::StoragePathEntry;
use starknet::{ContractAddress, ClassHash, get_caller_address};
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::storage::Map;
    use starknet::syscalls::deploy_syscall;
    use core::traits::Into;
    use core::traits::TryInto;
    // use core::array::SpanTrait;
    use core::array::ArrayTrait;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc721::ERC721Component;
    use openzeppelin::token::erc721::extensions::ERC721EnumerableComponent;
    use relaunch::interfaces::Imemecoin::{IMemeDispatcher, IMemeDispatcherTrait};
    use relaunch::interfaces::Irelaunch::IRelaunch;

    // Constants
    const DEPLOYER_ROLE: felt252 = 'DEPLOYER_ROLE';
    const POSITION_MANAGER_ROLE: felt252 = 'POSITION_MANAGER_ROLE';

    // Component declarations
    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: ERC721EnumerableComponent, storage: erc721_enumerable, event: ERC721EnumerableEvent);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: AccessControlComponent, storage: access_control, event: AccessControlEvent);

    // External implementations
    #[abi(embed_v0)]
    impl ERC721MixinImpl = ERC721Component::ERC721MixinImpl<ContractState>;
    #[abi(embed_v0)]
    impl ERC721EnumerableImpl = ERC721EnumerableComponent::ERC721EnumerableImpl<ContractState>;
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    #[abi(embed_v0)]
    impl AccessControlImpl = AccessControlComponent::AccessControlImpl<ContractState>;
    #[abi(embed_v0)]
    impl AccessControlCamelImpl = AccessControlComponent::AccessControlCamelImpl<ContractState>;

    // Internal implementations
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;
    impl ERC721EnumerableInternalImpl = ERC721EnumerableComponent::InternalImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        erc721_enumerable: ERC721EnumerableComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        access_control: AccessControlComponent::Storage,

        // Custom storage
        meme_factory: ClassHash,                            // Class hash for memecoin deployment
        memecoin_contracts: Map<u256, ContractAddress>,     // token_id -> memecoin address
        memecoin_treasury: Map<u256, ContractAddress>,      // token_id -> treasury address
        last_token_id: u256,                                // Counter for token IDs
        memecoin_to_token_id: Map<ContractAddress, u256>,   // memecoin address -> token_id
        position_manager: ContractAddress,                  // Position manager contract address
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        ERC721EnumerableEvent: ERC721EnumerableComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        MemecoinCreated: MemecoinCreated,
        TreasuryUpdated: TreasuryUpdated,
        MemeFactoryUpdated: MemeFactoryUpdated,
        PositionManagerUpdated: PositionManagerUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct MemecoinCreated {
        #[key]
        creator: ContractAddress,
        #[key]
        token_id: u256,
        #[key]
        memecoin: ContractAddress,
        name: ByteArray,
        symbol: ByteArray,
        token_uri: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct TreasuryUpdated {
        #[key]
        token_id: u256,
        #[key]
        treasury: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct MemeFactoryUpdated {
        #[key]
        meme_factory: ClassHash,
    }

    #[derive(Drop, starknet::Event)]
    struct PositionManagerUpdated {
        #[key]
        position_manager: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        base_uri: ByteArray,
        meme_factory: ClassHash,
        admin: ContractAddress
    ) {
        // Initialize components
        self.erc721.initializer(name, symbol, base_uri);
        self.erc721_enumerable.initializer();
        self.ownable.initializer(admin);
        self.access_control.initializer();
        
        // Grant admin the deployer role
        self.access_control._grant_role(DEPLOYER_ROLE, admin);
        self.access_control._grant_role(POSITION_MANAGER_ROLE, admin);
        
        // Set up custom storage
        self.meme_factory.write(meme_factory);
        self.last_token_id.write(0);
        
        // todo: Initialize position manager to zero address until set
        self.position_manager.write(get_caller_address());
    }

    #[abi(embed_v0)]
    impl RelaunchImpl of IRelaunch<ContractState> {
        // View functions
        fn memecoin_contract(self: @ContractState, token_id: u256) -> ContractAddress {
            self.memecoin_contracts.entry(token_id).read()
        }
        
        fn memecoin_treasury(self: @ContractState, token_id: u256) -> ContractAddress {
            self.memecoin_treasury.entry(token_id).read()
        }
        
        fn memecoin_to_token_id(self: @ContractState, memecoin: ContractAddress) -> u256 {
            self.memecoin_to_token_id.entry(memecoin).read()
        }

        fn last_token_id(self: @ContractState) -> u256 {
            self.last_token_id.read()
        }

        fn meme_factory(self: @ContractState) -> ClassHash {
            self.meme_factory.read()
        }
        
        fn position_manager(self: @ContractState) -> ContractAddress {
            self.position_manager.read()
        }
        
        fn memecoin_token_uri(self: @ContractState, token_id: u256) -> ByteArray {
            self._get_memecoin_token_uri(token_id)
        }

        // Core functionality
        fn relaunch(
            ref self: ContractState,
            name: ByteArray,
            symbol: ByteArray,
            token_uri: ByteArray,
            initial_supply: u256,
            treasury: ContractAddress
        ) -> (ContractAddress, u256) {
            // Check deployer role
            self._assert_only_deployer();
            
            let caller = get_caller_address();
            
            // Increment token ID
            let token_id = self.last_token_id.read() + 1;
            self.last_token_id.write(token_id);
            
            // Create unique salt from caller and token_id
            let mut salt_array = ArrayTrait::new();
            salt_array.append(caller.into());
            salt_array.append(token_id.try_into().unwrap());
            let salt = poseidon_hash_span(salt_array.span());
            
            // Deploy memecoin contract
            let (memecoin_address, _) = deploy_syscall(
                self.meme_factory.read(),
                salt,
                ArrayTrait::new().span(),  // Empty constructor args
                false
            ).unwrap();
            
            // Initialize the memecoin
            let mut memecoin = IMemeDispatcher { contract_address: memecoin_address };
            memecoin.initialize(name, symbol, token_uri);
            memecoin.set_token_id(token_id);
            
            // Mint initial supply to creator
            memecoin.mint(caller, initial_supply);
            
            // Store state
            self.memecoin_contracts.entry(token_id).write(memecoin_address);
            self.memecoin_treasury.entry(token_id).write(treasury);
            self.memecoin_to_token_id.entry(memecoin_address).write(token_id);
            
            // Mint NFT to creator
            self.erc721.mint(caller, token_id);
            
            // Emit event
            // self.emit(MemecoinCreated {
            //     creator: caller,
            //     token_id,
            //     memecoin: memecoin_address,
            //     name,
            //     symbol,
            //     token_uri,
            // });
            
            (memecoin_address, token_id)
        }
        
        // Position Manager functions (to be used with future position manager)
        fn create_memecoin_from_position_manager(
            ref self: ContractState,
            creator: ContractAddress,
            name: ByteArray,
            symbol: ByteArray,
            token_uri: ByteArray,
            initial_supply: u256,
            treasury: ContractAddress
        ) -> (ContractAddress, u256) {
            // Ensure caller is position manager
            self._assert_only_position_manager();
            
            // Increment token ID
            let token_id = self.last_token_id.read() + 1;
            self.last_token_id.write(token_id);
            
            // Create unique salt from creator and token_id
            let mut salt_array = ArrayTrait::new();
            salt_array.append(creator.into());
            salt_array.append(token_id.try_into().unwrap());
            let salt = poseidon_hash_span(salt_array.span());
            
            // Deploy memecoin contract
            let (memecoin_address, _) = deploy_syscall(
                self.meme_factory.read(),
                salt,
                ArrayTrait::new().span(),  // Empty constructor args
                false
            ).unwrap();
            
            // Initialize the memecoin
            let mut memecoin = IMemeDispatcher { contract_address: memecoin_address };
            memecoin.initialize(name, symbol, token_uri);
            memecoin.set_token_id(token_id);
            
            // Mint initial supply to creator
            memecoin.mint(creator, initial_supply);
            
            // Store state
            self.memecoin_contracts.entry(token_id).write(memecoin_address);
            self.memecoin_treasury.entry(token_id).write(treasury);
            self.memecoin_to_token_id.entry(memecoin_address).write(token_id);
            
            // Mint NFT to creator
            self.erc721.mint(creator, token_id);
            
            // Emit event
            // self.emit(MemecoinCreated {
            //     creator,
            //     token_id,
            //     memecoin: memecoin_address,
            //     name,
            //     symbol,
            //     token_uri,
            // });
            
            (memecoin_address, token_id)
        }

        // Admin functions
        fn set_meme_factory(ref self: ContractState, meme_factory: ClassHash) {
            // Only owner can set factory
            self.ownable.assert_only_owner();
            
            self.meme_factory.write(meme_factory);
            
            // Emit event
            self.emit(MemeFactoryUpdated { meme_factory });
        }
        
        fn set_position_manager(ref self: ContractState, position_manager: ContractAddress) {
            // Only owner can set position manager
            self.ownable.assert_only_owner();
            
            self.position_manager.write(position_manager);
            
            // Grant position manager role to the contract
            self.access_control._grant_role(POSITION_MANAGER_ROLE, position_manager);
            
            // Emit event
            self.emit(PositionManagerUpdated { position_manager });
        }

        fn set_memecoin_treasury(ref self: ContractState, token_id: u256, treasury: ContractAddress) {
            let caller = get_caller_address();
            
            // Check if caller is the owner of the token
            assert(
                self.erc721.owner_of(token_id) == caller,
                'Caller is not token owner'
            );
            
            self.memecoin_treasury.entry(token_id).write(treasury);
            
            // Emit event
            self.emit(TreasuryUpdated { token_id, treasury });
        }

        fn set_base_uri(ref self: ContractState, base_uri: ByteArray) {
            // Only owner can set base URI
            self.ownable.assert_only_owner();
            
            // Update base URI in ERC721
            self.erc721._set_base_uri(base_uri);
        }

        // Role management
        fn grant_deployer_role(ref self: ContractState, account: ContractAddress) {
            // Only admin can grant roles
            self.ownable.assert_only_owner();
            
            self.access_control._grant_role(DEPLOYER_ROLE, account);
        }

        fn revoke_deployer_role(ref self: ContractState, account: ContractAddress) {
            // Only admin can revoke roles
            self.ownable.assert_only_owner();
            
            self.access_control._revoke_role(DEPLOYER_ROLE, account);
        }

        fn has_deployer_role(self: @ContractState, account: ContractAddress) -> bool {
            self.access_control.has_role(DEPLOYER_ROLE, account)
        }
        
        fn grant_position_manager_role(ref self: ContractState, account: ContractAddress) {
            // Only admin can grant roles
            self.ownable.assert_only_owner();
            
            self.access_control._grant_role(POSITION_MANAGER_ROLE, account);
        }

        fn revoke_position_manager_role(ref self: ContractState, account: ContractAddress) {
            // Only admin can revoke roles
            self.ownable.assert_only_owner();
            
            self.access_control._revoke_role(POSITION_MANAGER_ROLE, account);
        }

        fn has_position_manager_role(self: @ContractState, account: ContractAddress) -> bool {
            self.access_control.has_role(POSITION_MANAGER_ROLE, account)
        }
    }

    // ERC721 hooks implementation following OZ pattern
    impl ERC721HooksImpl of ERC721Component::ERC721HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC721Component::ComponentState<ContractState>,
            to: ContractAddress,
            token_id: u256,
            auth: ContractAddress,
        ) {
            let mut contract_state = self.get_contract_mut();
            contract_state.erc721_enumerable.before_update(to, token_id);
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _assert_only_deployer(self: @ContractState) {
            let caller = get_caller_address();
            assert(
                self.access_control.has_role(DEPLOYER_ROLE, caller),
                'Caller is not a deployer'
            );
        }
        
        fn _assert_only_position_manager(self: @ContractState) {
            let caller = get_caller_address();
            let position_manager = self.position_manager.read();
            
            // Check if caller is position manager or has position manager role
            assert(
                caller == position_manager || self.access_control.has_role(POSITION_MANAGER_ROLE, caller),
                'Caller is not position manager'
            );
        }
        
        fn _get_memecoin_token_uri(self: @ContractState, token_id: u256) -> ByteArray {
            // Ensure token exists
            assert(self.erc721.exists(token_id), 'ERC721: invalid token ID');
            
            // Get memecoin address
            let memecoin_address = self.memecoin_contracts.entry(token_id).read();
            
            // Get token_uri from memecoin contract
            let memecoin = IMemeDispatcher { contract_address: memecoin_address };
            memecoin.token_uri()
        }
    }
}