### How to Use the ISP Extension in Your Ekubo Pool

To use the Internal Swap Pool (ISP) extension in your own Ekubo pool, follow these steps:

1. **Deploy the ISP Extension Contract**
	- Deploy the `InternalSwapPool` contract (see `src/contracts/internal_swap_pool.cairo`).
	- Note the contract address after deployment; this will be used as the extension address.

2. **Construct the PoolKey with the Extension**
	- When initializing or interacting with a pool, you must fill the `PoolKey` struct with the extension address:

	  ```cairo
	  let pool_key = PoolKey {
			token0: <address of token0>,
			token1: <address of token1>,
			fee: <fee as u128>,
			tick_spacing: <tick spacing>,
			extension: <address of your deployed InternalSwapPool>
	  };
	  ```
	- The `extension` field is the key: set it to the address of your deployed ISP contract. This tells Ekubo to use your custom extension logic for this pool.

3. **Initialize the Pool with the Custom Extension**
	- Use the Ekubo core contract's `initialize_pool` function, passing your custom `PoolKey`.
	- Example:
	  ```cairo
	  ekubo_core().initialize_pool(pool_key, initial_tick);
	  ```

4. **Interact via the Custom Router**
	- Use the provided custom router contract (`src/contracts/router.cairo`) to interact with pools that use the ISP extension. Standard routers will not work with custom extensions.
	- The router will handle swaps and other pool interactions, ensuring the extension logic is used.

5. **Testing and Experimentation**
	- See the test files in `src/tests/` for examples of how to deploy, initialize, and interact with pools using the ISP extension and custom router.

---

**Summary:**
- Deploy the ISP extension contract
- Set the `extension` field in your `PoolKey` to the ISP contract address
- Initialize the pool with this `PoolKey`
- Use the custom router to interact with the pool

This setup allows you to experiment with and build pools using custom fee logic on Ekubo.

