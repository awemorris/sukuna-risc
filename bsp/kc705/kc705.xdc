# ============================================================================
# Sukuna-RISC KC705 Constraints File (XDC)
# Target: xc7k325tffg900-2
# ============================================================================

# 200MHz Differential Clock (AD12 / AD11)
set_property PACKAGE_PIN AD12 [get_ports SYSCLK_P]
set_property IOSTANDARD DIFF_SSTL15 [get_ports SYSCLK_P]
set_property PACKAGE_PIN AD11 [get_ports SYSCLK_N]
set_property IOSTANDARD DIFF_SSTL15 [get_ports SYSCLK_N]

create_clock -period 5.000 -name sys_clk_pin [get_ports SYSCLK_P]

# CPU Reset Push Button (AB7) - Active High
set_property PACKAGE_PIN AB7 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS15 [get_ports CPU_RESET]

# USB UART
set_property PACKAGE_PIN M19 [get_ports USB_UART_TX]
set_property IOSTANDARD LVCMOS25 [get_ports USB_UART_TX]
set_property PACKAGE_PIN K24 [get_ports USB_UART_RX]
set_property IOSTANDARD LVCMOS25 [get_ports USB_UART_RX]

# GPIO LEDs
set_property PACKAGE_PIN AB8  [get_ports {GPIO_LED[0]}]
set_property IOSTANDARD LVCMOS15 [get_ports {GPIO_LED[0]}]
set_property PACKAGE_PIN AA8  [get_ports {GPIO_LED[1]}]
set_property IOSTANDARD LVCMOS15 [get_ports {GPIO_LED[1]}]
set_property PACKAGE_PIN AC9  [get_ports {GPIO_LED[2]}]
set_property IOSTANDARD LVCMOS15 [get_ports {GPIO_LED[2]}]
set_property PACKAGE_PIN AB9  [get_ports {GPIO_LED[3]}]
set_property IOSTANDARD LVCMOS15 [get_ports {GPIO_LED[3]}]
set_property PACKAGE_PIN AE26 [get_ports {GPIO_LED[4]}]
set_property IOSTANDARD LVCMOS25 [get_ports {GPIO_LED[4]}]
set_property PACKAGE_PIN G19  [get_ports {GPIO_LED[5]}]
set_property IOSTANDARD LVCMOS25 [get_ports {GPIO_LED[5]}]
set_property PACKAGE_PIN E18  [get_ports {GPIO_LED[6]}]
set_property IOSTANDARD LVCMOS25 [get_ports {GPIO_LED[6]}]
set_property PACKAGE_PIN F16  [get_ports {GPIO_LED[7]}]
set_property IOSTANDARD LVCMOS25 [get_ports {GPIO_LED[7]}]
