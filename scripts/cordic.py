"""Floating-point CORDIC reference model (circular, linear and hyperbolic)."""

import math


def shift_sequence(m, n_iter, reps=None):
    """
    Shift amounts j used by the iterations, in order.

    Circular and linear CORDIC use j = 0 .. n_iter-1. Hyperbolic CORDIC starts
    at j = 1 (atanh(2^0) is infinite) and repeats the j values in `reps`
    so that it converges.

    :param m: coordinate system: 1 circular, 0 linear, -1 hyperbolic
    :param n_iter: number of distinct shift values
    :param reps: shifts to repeat, hyperbolic only (e.g. [4, 13])
    :return: list of shift amounts
    """
    if m == -1:
        return sorted(list(range(1, n_iter + 1)) + list(reps or []))
    return list(range(n_iter))


def elementary_angle(m, j):
    """
    Angle removed from z by the iteration with shift j.

    :param m: coordinate system: 1 circular, 0 linear, -1 hyperbolic
    :param j: shift amount
    :return: atan(2^-j), 2^-j or atanh(2^-j)
    """
    if m == 1:
        return math.atan(2**-j)
    if m == -1:
        return math.atanh(2**-j)
    return 2**-j


def get_cordic_gain(m, n_iter, reps=None):
    """
    Gain K of the CORDIC.

    Each micro-rotation also scales the vector by sqrt(1 + m·2^(-2j)), so
    K = Π sqrt(1 + m·2^(-2j)) over the shift sequence: ≈ 1.6468 (circular),
    1 (linear), ≈ 0.8282 (hyperbolic).

    :param m: coordinate system: 1 circular, 0 linear, -1 hyperbolic
    :param n_iter: number of distinct shift values
    :param reps: shifts to repeat, hyperbolic only
    :return: gain K
    """
    return math.prod(math.sqrt(1 + m * 2**(-2 * j))
                     for j in shift_sequence(m, n_iter, reps))


def cordic_unified(x, y, z, mode, m, n_iter, reps=None):
    """
    Run the CORDIC iterations (results include the gain K).

    Rotation mode drives z to 0 (rotate (x, y) by z); vectoring mode drives y
    to 0 (accumulate the angle of (x, y) in z).

    :param x: initial x
    :param y: initial y
    :param z: initial angle
    :param mode: 'rotation' or 'vectoring'
    :param m: coordinate system: 1 circular, 0 linear, -1 hyperbolic
    :param n_iter: number of distinct shift values
    :param reps: shifts to repeat, hyperbolic only
    :return: final (x, y, z)
    """
    if mode not in ('rotation', 'vectoring'):
        raise ValueError("Invalid mode. Use 'rotation' or 'vectoring'.")

    for j in shift_sequence(m, n_iter, reps):
        if mode == 'rotation':
            sigma = 1 if z >= 0 else -1
        else:
            sigma = -1 if y >= 0 else 1
        x, y, z = (x - m * sigma * y * 2**-j,
                   y + sigma * x * 2**-j,
                   z - sigma * elementary_angle(m, j))
    return x, y, z


def cordic_sin_cos(angle_rad, n_iter=24):
    """
    Sine and cosine by circular rotation of (1/K, 0).

    :param angle_rad: angle in radians, |angle| < ~1.74
    :param n_iter: number of iterations
    :return: (sin, cos)
    """
    x0 = 1.0 / get_cordic_gain(m=1, n_iter=n_iter)
    cos_val, sin_val, _ = cordic_unified(x0, 0.0, angle_rad, 'rotation', m=1, n_iter=n_iter)
    return sin_val, cos_val


def cordic_multiply(x_val, z_val, n_iter=24):
    """
    Product x·z by linear rotation (z is halved into the convergence range).

    :param x_val: multiplicand
    :param z_val: multiplier
    :param n_iter: number of iterations
    :return: x_val · z_val
    """
    power = 0
    while abs(z_val) > 1.5:
        z_val /= 2.0
        power += 1
    _, product, _ = cordic_unified(x_val, 0.0, z_val, 'rotation', m=0, n_iter=n_iter)
    return product * 2**power


def cordic_divide(y_val, x_val, n_iter=24):
    """
    Quotient y/x by linear vectoring (y is halved until |y/x| ≤ 1.5).

    :param y_val: dividend
    :param x_val: divisor
    :param n_iter: number of iterations
    :return: y_val / x_val
    """
    power = 0
    while abs(y_val / x_val) > 1.5:
        y_val /= 2.0
        power += 1
    _, _, quotient = cordic_unified(x_val, y_val, 0.0, 'vectoring', m=0, n_iter=n_iter)
    return quotient * 2**power


def cordic_sqrt(val, n_iter=15):
    """
    Square root by hyperbolic vectoring of (val + 1/4, val - 1/4).

    :param val: radicand in about (0.03, 2)
    :param n_iter: number of distinct shift values (4 and 13 are repeated)
    :return: sqrt(val)
    """
    reps = [4, 13]
    x_n, _, _ = cordic_unified(val + 0.25, val - 0.25, 0.0, 'vectoring',
                               m=-1, n_iter=n_iter, reps=reps)
    return x_n / get_cordic_gain(m=-1, n_iter=n_iter, reps=reps)


def calculate_std_dev(data):
    """
    Sample standard deviation with CORDIC multiply, divide and sqrt.

    :param data: sequence of numbers
    :return: sample standard deviation (0.0 for fewer than 2 values)
    """
    if len(data) < 2:
        return 0.0

    n = len(data)
    mean = sum(data) / n
    sum_sq_diff = sum(cordic_multiply(x - mean, x - mean, n_iter=24) for x in data)
    variance = cordic_divide(sum_sq_diff, n - 1, n_iter=24)

    # Scale into the convergence range: sqrt(v · 4^k) = sqrt(v) · 2^k
    scale = 1.0
    while variance > 2.0:
        variance /= 4.0
        scale *= 2.0
    while 0 < variance < 0.25:
        variance *= 4.0
        scale /= 2.0

    return cordic_sqrt(variance, n_iter=15) * scale


def main():
    print("--- CORDIC Circular (Sine/Cosine) ---")
    for deg in [0, 30, 45, 60, 90]:
        th = math.radians(deg)
        s_val, c_val = cordic_sin_cos(th, 24)
        print(f"Angle {math.degrees(th):.1f}° | cordic_sin: {s_val:+.6f} cordic_cos: {c_val:+.6f}")

    print("\n--- CORDIC Linear (Multiplication/Division) ---")
    print(f"12.5 * 3.2  | CORDIC: {cordic_multiply(12.5, 3.2, 24):.5f} | Exact: {12.5 * 3.2}")
    print(f"15.75 / 4.5 | CORDIC: {cordic_divide(15.75, 4.5, 24):.5f} | Exact: {15.75 / 4.5}")

    print("\n--- CORDIC Hyperbolic (Square Root) ---")
    val = 1.69
    print(f"sqrt({val})    | CORDIC: {cordic_sqrt(val, 15):.5f} | Exact: {math.sqrt(val):.5f}")

    print("\n--- Practical Use: Standard Deviation ---")
    dataset = [82, 93, 98, 89, 88]
    mean = sum(dataset) / len(dataset)
    exact_sd = math.sqrt(sum((x - mean)**2 for x in dataset) / (len(dataset) - 1))
    print(f"Dataset: {dataset}")
    print(f"Standard Deviation | CORDIC: {calculate_std_dev(dataset):.6f} | Exact: {exact_sd:.6f}")


if __name__ == "__main__":
    main()
