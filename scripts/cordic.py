import math

def get_cordic_gain(m, n_iter, reps=None):
    """Calculates scaling factor K for given coordinate system"""
    k = 1.0
    if m == 1:
        for i in range(n_iter):
            k *= math.sqrt(1 + 2**(-2*i))
    elif m == -1:
        iters = list(range(1, n_iter + 1))
        if reps:
            iters.extend(reps)
            iters.sort()
        for i in iters:
            k *= math.sqrt(1 - 2**(-2*i))
    return k

def cordic_unified(x, y, z, mode, m, n_iter, reps=None):
    """
    Unified CORDIC algorithm.
    :param m: 1 (Circular), 0 (Linear), -1 (Hyperbolic)
    :param mode: 'rotation' or 'vectoring'
    """
    if m == -1:
        # Hyperbolic starts at j=1
        iters = list(range(1, n_iter + 1))
        # Look-up table for hyperbolic arctangent
        lut = {i: math.atanh(2**-i) for i in range(1, n_iter + 1)}
    else:
        # Circular and Linear start at j=0
        iters = list(range(n_iter))
        if m == 1:
            lut = {i: math.atan(2**-i) for i in range(n_iter)}
        else: # m == 0
            lut = {i: 2**-i for i in range(n_iter)}
            
    # Add repeated iterations for hyperbolic convergence
    if m == -1 and reps:
        iters.extend(reps)
        iters.sort()
        
    for j in iters:
        if mode == 'rotation':
            sigma = 1 if z >= 0 else -1
        elif mode == 'vectoring':
            sigma = -1 if y >= 0 else 1
        else:
            raise ValueError("Invalid mode. Use 'rotation' or 'vectoring'.")
            
        pow2_j = 2**-j
        
        x_next = x - m * sigma * y * pow2_j
        y_next = y + sigma * x * pow2_j
        z_next = z - sigma * lut[j]
        
        x, y, z = x_next, y_next, z_next
        
    return x, y, z

def cordic_sin_cos(angle_rad, n_iter=24):
    """ Computes Sine and Cosine (Circular Rotation) """
    K = get_cordic_gain(m=1, n_iter=n_iter)
    
    # Pre-scale X by 1/K so output is pure cos/sin
    x0 = 1.0 / K  
    y0 = 0.0
    z0 = angle_rad
    
    cos_val, sin_val, _ = cordic_unified(x0, y0, z0, mode='rotation', m=1, n_iter=n_iter)
    return sin_val, cos_val

def cordic_multiply(x_val, z_val, n_iter=24):
    """ Computes x * z (Linear Rotation) """
    # Scale z_val to be within the linear convergence domain [-2, 2]
    power = 0
    z_scaled = z_val
    while abs(z_scaled) > 1.5:
        z_scaled /= 2.0
        power += 1
        
    x0 = x_val
    y0 = 0.0
    z0 = z_scaled
    
    _, product, _ = cordic_unified(x0, y0, z0, mode='rotation', m=0, n_iter=n_iter)
    
    return product * (2**power)

def cordic_divide(y_val, x_val, n_iter=24):
    """ Computes y / x (Linear Vectoring) """
    # Scale y_val so that y_val / x_val is within the convergence domain [-2, 2]
    power = 0
    y_scaled = y_val
    while abs(y_scaled / x_val) > 1.5:
        y_scaled /= 2.0
        power += 1
        
    x0 = x_val
    y0 = y_scaled
    z0 = 0.0
    
    _, _, quotient = cordic_unified(x0, y0, z0, mode='vectoring', m=0, n_iter=n_iter)
    
    return quotient * (2**power)

def cordic_sqrt(val, n_iter=15):
    """ Computes sqrt(val) (Hyperbolic Vectoring) """
    # Hyperbolic CORDIC only converges for inputs in a specific domain.
    # For square root, the input `a` must satisfy certain conditions,
    # typically a is scaled such that it falls into the convergence domain.
    # We'll use a simple case here for demonstration.
    
    # K factor for Hyperbolic (requires repeated iterations 4, 13)
    reps = [4, 13]
    K = get_cordic_gain(m=-1, n_iter=n_iter, reps=reps)
    
    x0 = val + 0.25
    y0 = val - 0.25
    z0 = 0.0
    
    x_n, _, _ = cordic_unified(x0, y0, z0, mode='vectoring', m=-1, n_iter=n_iter, reps=reps)
    
    return x_n / K

def calculate_std_dev(data):
    """ Example calculating sample standard deviation using CORDIC """
    if not data or len(data) < 2:
        return 0.0
        
    n = len(data)
    
    # Mean
    sum_data = 0.0
    for x in data:
        # We could use cordic_divide here, but for simplicity of the example let's stick to true division for the mean
        sum_data += x
    mean = sum_data / n
    
    # Variance
    sum_sq_diff = 0.0
    for x in data:
        diff = x - mean
        sq_diff = cordic_multiply(diff, diff, n_iter=24)
        sum_sq_diff += sq_diff
        
    variance = cordic_divide(sum_sq_diff, n - 1, n_iter=24)
    
    # Standard Deviation (Sqrt)
    # We must scale the variance into the convergence range of hyperbolic CORDIC (~[0.03, 2])
    # The scaling uses properties of sqrt: sqrt(x * 4^k) = sqrt(x) * 2^k
    scale_factor = 1.0
    scaled_var = variance
    
    while scaled_var > 2.0:
        scaled_var /= 4.0
        scale_factor *= 2.0
    while scaled_var > 0 and scaled_var < 0.25:
        scaled_var *= 4.0
        scale_factor /= 2.0
        
    std_dev_scaled = cordic_sqrt(scaled_var, n_iter=15)
    std_dev = std_dev_scaled * scale_factor
    
    return std_dev


def main():
    print("--- CORDIC Circular (Sine/Cosine) ---")
    angles = [math.radians(a) for a in [0, 30, 45, 60, 90]]
    for th in angles:
        s_val, c_val = cordic_sin_cos(th, 24)
        print(f"Angle {math.degrees(th):.1f}° | cordic_sin: {s_val:+.6f} cordic_cos: {c_val:+.6f}")
        
    print("\n--- CORDIC Linear (Multiplication/Division) ---")
    mult_res = cordic_multiply(12.5, 3.2, 24)
    print(f"12.5 * 3.2  | CORDIC: {mult_res:.5f} | Exact: {12.5 * 3.2}")
    
    div_res = cordic_divide(15.75, 4.5, 24)
    print(f"15.75 / 4.5 | CORDIC: {div_res:.5f} | Exact: {15.75 / 4.5}")

    print("\n--- CORDIC Hyperbolic (Square Root) ---")
    val = 1.69
    sqrt_res = cordic_sqrt(val, 15)
    print(f"sqrt({val})    | CORDIC: {sqrt_res:.5f} | Exact: {math.sqrt(val):.5f}")

    print("\n--- Practical Use: Standard Deviation ---")
    dataset = [82, 93, 98, 89, 88]
    std_dev_cordic = calculate_std_dev(dataset)
    
    # Calculate exact for comparison
    mean = sum(dataset) / len(dataset)
    exact_var = sum((x - mean)**2 for x in dataset) / (len(dataset) - 1)
    exact_sd = math.sqrt(exact_var)
    
    print(f"Dataset: {dataset}")
    print(f"Standard Deviation | CORDIC: {std_dev_cordic:.6f} | Exact: {exact_sd:.6f}")


if __name__ == "__main__":
    main()