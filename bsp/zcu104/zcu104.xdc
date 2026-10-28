# ============================================================================
# Sukuna-RISC ZCU104 Constraints File (XDC)
# Target: xczu7ev-ffvc1156-2-e
# ============================================================================

# 125MHz Differential System Clock (CLK_125_P: F23, CLK_125_N: E23)
set_property PACKAGE_PIN F23 [get_ports CLK_125_P]
set_property IOSTANDARD LVDS [get_ports CLK_125_P]
set_property PACKAGE_PIN E23 [get_ports CLK_125_N]
set_property IOSTANDARD LVDS [get_ports CLK_125_N]

create_clock -period 8.000 -name sys_clk_pin [get_ports CLK_125_P]

# CPU Reset Push Button (SW13 / M11) - Active High
set_property PACKAGE_PIN M11 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS33 [get_ports CPU_RESET]

# USB UART
set_property PACKAGE_PIN A20 [get_ports UART_TX]
set_property IOSTANDARD LVCMOS18 [get_ports UART_TX]
set_property PACKAGE_PIN C19 [get_ports UART_RX]
set_property IOSTANDARD LVCMOS18 [get_ports UART_RX]

# GPIO LEDs
set_property PACKAGE_PIN D5 [get_ports {GPIO_LED[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_LED[0]}]
set_property PACKAGE_PIN D6 [get_ports {GPIO_LED[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_LED[1]}]
set_property PACKAGE_PIN A5 [get_ports {GPIO_LED[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_LED[2]}]
set_property PACKAGE_PIN B5 [get_ports {GPIO_LED[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_LED[3]}]
