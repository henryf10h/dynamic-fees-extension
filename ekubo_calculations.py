import math

class EkuboPoolCalculator:
    def __init__(self):
        self.token0 = None
        self.token1 = None
        self.fee = None
        self.tick_spacing = None
        self.initial_tick = None
        self.sqrt_ratio = None
        self.initial_price = None
    
    def assign_tokens(self, address1, address2):
        """
        Compare two token addresses and assign them as token0 (min) and token1 (max)
        """
        # Convert hex strings to integers for comparison
        addr1_int = int(address1, 16)
        addr2_int = int(address2, 16)
        
        # Assign based on numerical value
        self.token0 = min(address1, address2, key=lambda x: int(x, 16))
        self.token1 = max(address1, address2, key=lambda x: int(x, 16))
        
        print(f"Token0 (smaller): {self.token0}")
        print(f"Token1 (larger): {self.token1}")
        return self.token0, self.token1
    
    def calculate_fee(self, fee_percent):
        """
        Calculate fee using the formula: floor(fee_percent * 2^128)
        """
        fee_decimal = fee_percent / 100
        self.fee = math.floor(fee_decimal * 2**128)
        print(f"Fee percentage: {fee_percent}%")
        print(f"Fee calculated: {self.fee}")
        return self.fee
    
    def calculate_fee_interactive(self):
        """
        Interactive function to get fee from user input
        """
        print("\nFee Input:")
        print("Examples: 0.3 (for 0.3%), 1 (for 1%), 0.05 (for 0.05%)")
        try:
            fee_percent = float(input("Enter desired fee percentage: "))
            return self.calculate_fee(fee_percent)
        except ValueError:
            print("Error: Please enter a valid number!")
            return None
    
    def calculate_tick_spacing(self, tick_spacing_percent):
        """
        Calculate tick spacing using: log(1 + tick_spacing_percent, 1.000001)
        """
        tick_spacing_decimal = tick_spacing_percent / 100
        self.tick_spacing = int(math.log(1 + tick_spacing_decimal, 1.000001))
        print(f"Tick spacing percentage: {tick_spacing_percent}%")
        print(f"Tick spacing: {self.tick_spacing}")
        return self.tick_spacing
    
    def calculate_tick_spacing_interactive(self):
        """
        Interactive function to get tick spacing from user input
        """
        print("\nTick Spacing Input:")
        print("Examples: 0.1 (for 0.1%), 0.05 (for 0.05%), 1 (for 1%)")
        try:
            tick_spacing_percent = float(input("Enter desired tick spacing percentage: "))
            return self.calculate_tick_spacing(tick_spacing_percent)
        except ValueError:
            print("Error: Please enter a valid number!")
            return None
    
    def calculate_sqrt_ratio_and_tick(self, token1_amount, token0_amount):
        """
        Calculate sqrt_ratio and initial_tick from token amounts
        sqrt_ratio = sqrt(token1_amount / token0_amount)
        initial_tick = log_1.000001(sqrt_ratio)
        """
        # Calculate sqrt ratio
        price_ratio = token1_amount / token0_amount
        self.sqrt_ratio = math.sqrt(price_ratio)
        self.initial_price = price_ratio 
        
        # Calculate initial tick using log base 1.000001
        self.initial_tick = math.log(self.sqrt_ratio) / math.log(math.sqrt(1.000001))
        self.initial_tick = int(self.initial_tick)
        
        print(f"Token1 amount: {token1_amount}")
        print(f"Token0 amount: {token0_amount}")
        print(f"Price ratio (token1/token0): {price_ratio}")
        print(f"Sqrt ratio: {self.sqrt_ratio}")
        print(f"Initial tick: {self.initial_tick}")
        
        return self.sqrt_ratio, self.initial_tick
    
    def calculate_sqrt_ratio_and_tick_interactive(self):
        """
        Interactive function to get token amounts from user and calculate sqrt ratio and tick
        """
        if not self.token0 or not self.token1:
            print("Error: Please assign tokens first!")
            return None, None
        
        print(f"\nToken Amount Input:")
        print(f"Token0 (smaller address): {self.token0}")
        print(f"Token1 (larger address): {self.token1}")
        print("Enter the amounts you want to add for liquidity:")
        
        try:
            token0_amount = float(input("Enter Token0 amount: "))
            token1_amount = float(input("Enter Token1 amount: "))
            
            if token0_amount <= 0 or token1_amount <= 0:
                print("Error: Token amounts must be positive!")
                return None, None
            
            # Store amounts for later liquidity calculations
            self.token0_amount = token0_amount
            self.token1_amount = token1_amount
            
            return self.calculate_sqrt_ratio_and_tick(token1_amount, token0_amount)
            
        except ValueError:
            print("Error: Please enter valid numbers!")
            return None, None
    
    def calculate_bounds_interactive(self):
        """
        Interactive function to get bounds from user input
        """
        if self.initial_price is None:
            print("Error: Please calculate initial tick first!")
            return None, None
        
        print(f"\nCurrent initial price (token1/token0): {self.initial_price}")
        print("Please provide the price range for liquidity provision:")
        
        try:
            lower_price = float(input("Enter lower bound price: "))
            upper_price = float(input("Enter upper bound price: "))
            
            if lower_price >= upper_price:
                print("Error: Lower price must be less than upper price!")
                return None, None
            
            if lower_price > self.initial_price or upper_price < self.initial_price:
                print("Warning: Initial price is outside the specified range!")
            
            # Convert prices to ticks
            lower_sqrt_ratio = math.sqrt(lower_price) 
            upper_sqrt_ratio = math.sqrt(upper_price) 
            
            lower_tick = int(math.log(lower_sqrt_ratio) / math.log(math.sqrt(1.000001)))
            upper_tick = int(math.log(upper_sqrt_ratio) / math.log(math.sqrt(1.000001)))
            
            # Round ticks to valid tick spacing if tick_spacing is set
            if self.tick_spacing is not None:
                lower_tick_rounded = self.round_tick_to_spacing(lower_tick, self.tick_spacing)
                upper_tick_rounded = self.round_tick_to_spacing(upper_tick, self.tick_spacing)
                
                print(f"Original ticks - Lower: {lower_tick}, Upper: {upper_tick}")
                print(f"Rounded to tick spacing ({self.tick_spacing}):")
                print(f"Lower bound - Price: {lower_price}, Tick: {lower_tick_rounded}")
                print(f"Upper bound - Price: {upper_price}, Tick: {upper_tick_rounded}")
                
                return (lower_tick_rounded, upper_tick_rounded), (lower_price, upper_price)
            else:
                print(f"Lower bound - Price: {lower_price}, Tick: {lower_tick}")
                print(f"Upper bound - Price: {upper_price}, Tick: {upper_tick}")
                return (lower_tick, upper_tick), (lower_price, upper_price)
            
        except ValueError:
            print("Error: Please enter valid numbers!")
            return None, None
    
    def round_tick_to_spacing(self, tick, tick_spacing):
        """
        Round tick to the nearest valid tick that's a multiple of tick_spacing
        """
        return round(tick / tick_spacing) * tick_spacing
    
    def calculate_bounds_automatic(self, lower_price, upper_price):
        """
        Calculate bounds given specific price values
        """
        if lower_price >= upper_price:
            print("Error: Lower price must be less than upper price!")
            return None, None
        
        # Convert prices to ticks
        lower_sqrt_ratio = math.sqrt(lower_price) 
        upper_sqrt_ratio = math.sqrt(upper_price) 
        
        lower_tick = int(math.log(lower_sqrt_ratio) / math.log(math.sqrt(1.000001)))
        upper_tick = int(math.log(upper_sqrt_ratio) / math.log(math.sqrt(1.000001)))
        
        # Round ticks to valid tick spacing if tick_spacing is set
        if self.tick_spacing is not None:
            lower_tick_rounded = self.round_tick_to_spacing(lower_tick, self.tick_spacing)
            upper_tick_rounded = self.round_tick_to_spacing(upper_tick, self.tick_spacing)
            
            print(f"Original ticks - Lower: {lower_tick}, Upper: {upper_tick}")
            print(f"Rounded to tick spacing ({self.tick_spacing}):")
            print(f"Lower bound - Price: {lower_price}, Tick: {lower_tick_rounded}")
            print(f"Upper bound - Price: {upper_price}, Tick: {upper_tick_rounded}")
            
            return (lower_tick_rounded, upper_tick_rounded), (lower_price, upper_price)
        else:
            print(f"Lower bound - Price: {lower_price}, Tick: {lower_tick}")
            print(f"Upper bound - Price: {upper_price}, Tick: {upper_tick}")
            return (lower_tick, upper_tick), (lower_price, upper_price)
    
    def calculate_min_liquidity(self, token0_amount, token1_amount, lower_price, upper_price):
        """
        Calculate minimum liquidity using Uniswap v3 formulas:
        For token0: L = amount0 * (√P_a * √P_b) / (√P_b - √P_a)
        For token1: L = amount1 / (√P_b - √P_a)
        
        Where P_a is lower price and P_b is upper price
        """
        # Calculate square roots of price bounds
        sqrt_P_a = math.sqrt(lower_price) 
        sqrt_P_b = math.sqrt(upper_price) 
        
        # Calculate liquidity from token0
        # L = amount0 * (√P_a * √P_b) / (√P_b - √P_a)
        numerator_token0 = token0_amount * (sqrt_P_a * sqrt_P_b)
        denominator = sqrt_P_b - sqrt_P_a
        L_from_token0 = numerator_token0 / denominator
        
        # Calculate liquidity from token1
        # L = amount1 / (√P_b - √P_a)
        L_from_token1 = token1_amount / denominator
        
        # The minimum liquidity is the limiting factor
        min_liquidity = min(L_from_token0, L_from_token1)
        
        print(f"\nLiquidity Calculations:")
        print(f"√P_a (lower): {sqrt_P_a}")
        print(f"√P_b (upper): {sqrt_P_b}")
        print(f"√P_b - √P_a: {denominator}")
        print(f"Liquidity from Token0: {L_from_token0}")
        print(f"Liquidity from Token1: {L_from_token1}")
        print(f"Minimum Liquidity: {min_liquidity}")
        
        return min_liquidity, L_from_token0, L_from_token1
    
    def calculate_min_liquidity_interactive(self):
        """
        Interactive calculation of minimum liquidity using stored values
        """
        # Check if all required values are available
        if not hasattr(self, 'token0_amount') or not hasattr(self, 'token1_amount'):
            print("Error: Token amounts not set! Please calculate sqrt ratio first.")
            return None
        
        # Get bounds interactively if not set
        bounds_result = self.calculate_bounds_interactive()
        if not bounds_result[0]:
            return None
        
        ticks, prices = bounds_result
        lower_price, upper_price = prices
        
        # Calculate minimum liquidity
        return self.calculate_min_liquidity(
            self.token0_amount, 
            self.token1_amount, 
            lower_price, 
            upper_price
        )
    
    def print_summary(self):
        """
        Print a summary of all calculated values
        """
        print("\n" + "="*50)
        print("EKUBO POOL CALCULATION SUMMARY")
        print("="*50)
        print(f"Token0 (smaller): {self.token0}")
        print(f"Token1 (larger): {self.token1}")
        if hasattr(self, 'token0_amount') and hasattr(self, 'token1_amount'):
            print(f"Token0 amount: {self.token0_amount}")
            print(f"Token1 amount: {self.token1_amount}")
        print(f"Fee: {self.fee}")
        print(f"Tick spacing: {self.tick_spacing}")
        print(f"Initial price: {self.initial_price}")
        print(f"Sqrt ratio: {self.sqrt_ratio}")
        print(f"Initial tick: {self.initial_tick}")
        
        # Add liquidity info if calculated
        if hasattr(self, 'min_liquidity'):
            print(f"Minimum Liquidity: {self.min_liquidity}")
        if hasattr(self, 'liquidity_bounds'):
            print(f"Price Range: {self.liquidity_bounds[0]} - {self.liquidity_bounds[1]}")
        
        print("="*50)

# Example usage and testing
def main():
    calculator = EkuboPoolCalculator()
    
    # Example addresses from your request
    address1 = "0x00abbd6f1e590eb83addd87ba5ac27960d859b1f17d11a3c1cd6a0006704b141"
    address2 = "0x0275d08f64e8c9da4aea46168979205d309fdd079c5a5b4df4252df1cb72ab0f"
    
    print("EKUBO STARKNET POOL CALCULATOR")
    print("="*40)
    
    print("1. Assigning tokens...")
    calculator.assign_tokens(address1, address2)
    
    print("\n2. Getting liquidity amounts from user...")
    calculator.calculate_sqrt_ratio_and_tick_interactive()
    
    print("\n3. Getting fee configuration...")
    calculator.calculate_fee_interactive()
    
    print("\n4. Getting tick spacing configuration...")
    calculator.calculate_tick_spacing_interactive()
    
    print("\n5. Calculating bounds and minimum liquidity...")
    bounds_result = calculator.calculate_bounds_interactive()
    
    if bounds_result and bounds_result[0]:
        ticks, prices = bounds_result
        print(f"\nCalculating minimum liquidity...")
        
        # Calculate minimum liquidity
        liquidity_result = calculator.calculate_min_liquidity(
            calculator.token0_amount,
            calculator.token1_amount,
            prices[0],  # lower_price
            prices[1]   # upper_price
        )
        
        if liquidity_result:
            min_liq, l_token0, l_token1 = liquidity_result
            calculator.min_liquidity = min_liq
            calculator.liquidity_bounds = prices
            
            print(f"\n🔥 POOL SETUP COMPLETE! 🔥")
    
    # Print summary
    calculator.print_summary()
    
    return calculator

def interactive_demo():
    """
    Complete interactive demo for pool setup
    """
    calculator = EkuboPoolCalculator()
    
    print("EKUBO STARKNET POOL CALCULATOR - INTERACTIVE DEMO")
    print("="*50)
    
    # Get token addresses
    print("1. Token Address Input:")
    try:
        addr1 = input("Enter first token address: ").strip()
        addr2 = input("Enter second token address: ").strip()
        
        if not addr1.startswith('0x') or not addr2.startswith('0x'):
            print("Warning: Addresses should start with '0x'")
        
        calculator.assign_tokens(addr1, addr2)
    except Exception as e:
        print(f"Error with addresses: {e}")
        return None
    
    # Get liquidity amounts
    print("\n2. Liquidity amounts:")
    result = calculator.calculate_sqrt_ratio_and_tick_interactive()
    if not result[0]:
        return None
    
    # Get fee
    print("\n3. Fee configuration:")
    fee_result = calculator.calculate_fee_interactive()
    if not fee_result:
        return None
    
    # Get tick spacing
    print("\n4. Tick spacing:")
    tick_result = calculator.calculate_tick_spacing_interactive()
    if not tick_result:
        return None
    
    # Get bounds and calculate liquidity
    print("\n5. Liquidity range bounds and minimum liquidity calculation:")
    bounds_result = calculator.calculate_bounds_interactive()
    
    if bounds_result[0]:
        ticks, prices = bounds_result
        print(f"\nLiquidity Range:")
        print(f"Lower: Price {prices[0]}, Tick {ticks[0]}")
        print(f"Upper: Price {prices[1]}, Tick {ticks[1]}")
        
        # Verify ticks are multiples of tick spacing
        lower_tick, upper_tick = ticks
        if calculator.tick_spacing:
            print(f"\n🔧 TICK SPACING VERIFICATION:")
            print(f"Lower tick {lower_tick} ÷ {calculator.tick_spacing} = {lower_tick / calculator.tick_spacing}")
            print(f"Upper tick {upper_tick} ÷ {calculator.tick_spacing} = {upper_tick / calculator.tick_spacing}")
            
            if lower_tick % calculator.tick_spacing == 0 and upper_tick % calculator.tick_spacing == 0:
                print("✅ Ticks are correctly aligned to tick spacing!")
            else:
                print("❌ Ticks are NOT aligned to tick spacing - this will cause errors!")
        
        # Calculate minimum liquidity
        liquidity_result = calculator.calculate_min_liquidity(
            calculator.token0_amount,
            calculator.token1_amount,
            prices[0],  # lower_price
            prices[1]   # upper_price
        )
        
        if liquidity_result:
            min_liq, l_token0, l_token1 = liquidity_result
            calculator.min_liquidity = min_liq
            calculator.liquidity_bounds = prices
            
            print(f"\n🔥 LIQUIDITY CALCULATION COMPLETE! 🔥")
            print(f"Your pool is ready with minimum liquidity: {min_liq}")
            
            # Show final command format
            print(f"\n📋 STARKLI COMMAND FORMAT:")
            print(f"Use these values in your starkli command:")
            print(f"- Lower Tick: {ticks[0]}")
            print(f"- Upper Tick: {ticks[1]}")
            print(f"- Fee: {calculator.fee}")
            print(f"- Tick Spacing: {calculator.tick_spacing}")
    
    # Final summary
    calculator.print_summary()
    
    return calculator

if __name__ == "__main__":
    print("Choose mode:")
    print("1. Example with predefined addresses (press 1)")
    print("2. Full interactive demo (press 2)")
    print("3. Fix your tick spacing issue (press 3)")
    
    try:
        choice = input("Enter choice (1, 2, or 3): ").strip()
        if choice == "1":
            calc = main()
        elif choice == "2":
            calc = interactive_demo()
        elif choice == "3":
            # Quick fix for the user's specific case
            calc = EkuboPoolCalculator()
            calc.get_corrected_ticks_for_your_case()
        else:
            print("Invalid choice, running example mode...")
            calc = main()
    except KeyboardInterrupt:
        print("\nExiting...")
    except Exception as e:
        print(f"Error: {e}")