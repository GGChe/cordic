# CORDIC (COordinate Rotation DIgital Computer)

CORDIC is a highly efficient hardware-oriented algorithm designed to compute complex mathematical functions using only fundamental **shift** and **add** operations. By completely eliminating the need for expensive hardware multipliers, it is especially well-suited for FPGA and ASIC hardware implementations where silicon area, power consumption, and clock speed are critical constraints.

## Core Principles

The CORDIC algorithm operates on the principle of **successive micro-rotations**. By iteratively rotating a vector by a sequence of pre-defined, progressively decreasing angles, it can traverse to any desired angle or converge to a target magnitude. 

The brilliant insight of CORDIC is that these pre-defined rotation angles ($\alpha_i$) are specifically chosen such that their tangent is a descending power of 2 (e.g., $\tan(\alpha_i) = 2^{-i}$). This specific mathematical choice allows the matrix rotation calculations to be simplified into hardware-friendly bit-shift and addition/subtraction steps, completely bypassing traditional complex multiplication.

## Operating Modes

The algorithm primarily operates in two distinct modes, depending on the variable driven to zero:

1. **Rotation Mode**: The target angle ($Z$) is iteratively pushed towards zero. The sequence of micro-rotations is determined by the sign of the remaining angle. This mode is used to rotate an input vector by a predetermined angle, which is essential for calculating trigonometric functions like **Sine** and **Cosine**.
2. **Vectoring Mode**: The vector's y-coordinate ($Y$) is iteratively driven to zero, effectively rotating the vector to align with the positive x-axis. The total angle accumulated from these rotations gives the original phase, and the final x-coordinate represents the magnitude. This is used for functions like **Arctangent** and calculating vector magnitude.

## Unified Coordinate Systems

A unified mathematical description of CORDIC introduces a system parameter $m$ to extend the algorithm beyond circular rotations:

* **Circular ($m = 1$)**: For trigonometric functions ($\sin$, $\cos$, $\arctan$), phase, and magnitude (e.g., polar-to-rectangular / rectangular-to-polar coordinate conversions).
* **Linear ($m = 0$)**: The trajectory is linear rather than curved. Used for basic multiplication and division.
* **Hyperbolic ($m = -1$)**: The trajectory follows a hyperbolic curve. Used to compute hyperbolic functions ($\sinh$, $\cosh$, $\text{arctanh}$), natural logarithms, exponentials, and square roots.

## Hardware Architectures

Implementations at the RTL level typically fall into two main architectural patterns:

* **Word-Serial (Iterative)**: Uses a single shift-and-add hardware unit that loops its output back to its input, iterating $N$ times. It is exceptionally slow ($N$ clock cycles per result) but requires the absolute minimum logic area.
* **Unrolled / Pipelined**: Cascades $N$ distinct processing stages, one for each micro-rotation. Each stage is hardwired for its specific bit-shift amount, avoiding programmable shifters. This architecture provides high throughput (one result per clock cycle) at the cost of a considerably larger silicon footprint.

## Advanced Execution Concepts

To achieve higher performance and precision, modern advanced CORDIC processor designs often employ:
* **Redundant Representation**: Employing carry-save or signed-digit arithmetic architectures to avoid slow ripple-carry propagation paths during standard additions.
* **High Radix**: Implementing Radix-4 or Radix-8 structures to resolve and process multiple bits per iteration step, actively reducing the total number of required rotations (latency).
* **Double / Repeated Rotation**: Often necessary in hyperbolic CORDIC ($m=-1$) where convergence is not guaranteed for specific iteration indices (like $i=4, 13, 40...$), requiring certain iterations to be repeated, or used to compensate for the inherent CORDIC scale factor variations without requiring post-multiplication.



