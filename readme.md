
# Dynamic-fees-extension: Enabling Custom Fee Models on Ekubo
This project introduces a foundational Internal Swap Pool (ISP) for Ekubo DEX, designed to open up the world of custom dynamic fees on Starknet.

We're moving beyond static fee structures. The Dynamic-fees-extension serves as a proof-of-concept, demonstrating how a modular and intuitive framework can allow developers to build and deploy their own unique fee models.

---


## Technical Guidance: Building, Testing, and Exploring the Codebase
### Key Contracts to Explore

The two main contracts to study in this project are:

- **InternalSwapPool** (`src/contracts/internal_swap_pool.cairo`):
	- This is the core ISP (Internal Swap Pool) extension contract. It implements the custom fee logic and is the main point of extension for dynamic fee models.
- **Router** (`src/contracts/router.cairo`):
	- This is a custom router contract designed specifically to interact with the ISP extension. Standard routers will not work with the custom ISP, so this contract handles the correct call structure and data formatting required to route swaps through the extension.

If you want to experiment with or extend the dynamic fee logic, start by reading and modifying `internal_swap_pool.cairo`. To see how swaps are routed and how the extension is called, review `router.cairo` and the test files in `src/tests/`.

**Note:** A custom router is required because the ISP extension interface is not compatible with the default Ekubo router. The custom router ensures that all swap and pool interactions are correctly dispatched to the extension contract.


This project uses [Scarb](https://docs.swmansion.com/scarb/) as the Cairo package manager and build tool.

### Prerequisites

- [Install Scarb](https://docs.swmansion.com/scarb/download.html) (ensure you have the latest version)
- [Install Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) for running tests

### Building the Project

To build all contracts and dependencies, run:

```sh
scarb build
```

Artifacts will be generated in the `target/` directory.

### Running Tests

To run all integration and unit tests:

```sh
scarb test
```

Test files are located in the `src/tests/` directory. You can add your own tests or modify existing ones to experiment with the contracts.

### Common Scarb Commands

- `scarb build` — Compile the project
- `scarb test` — Run all tests
- `scarb fmt` — Format your Cairo code

### Troubleshooting

- If you encounter errors, ensure your Scarb and Starknet Foundry versions are up to date.
- For contract deployment and interaction, refer to the contract addresses and dispatcher patterns in the test files.

---

For more details, see the [Scarb documentation](https://docs.swmansion.com/scarb/) and [Starknet Foundry docs](https://foundry-rs.github.io/starknet-foundry/).

