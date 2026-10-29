## ============================================================================
## KC705 Constraints for Sukuna-RISC (xc7k325tffg900-2)
## ============================================================================

## 200MHz System Differential Clock
set_property PACKAGE_PIN AD12 [get_ports sysclk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sysclk_p]
set_property PACKAGE_PIN AD11 [get_ports sysclk_n]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sysclk_n]

create_clock -period 5.000 -name clk_200m [get_ports sysclk_p]

## CPU Reset (Button AB7)
set_property PACKAGE_PIN AB7 [get_ports cpu_reset_i]
set_property IOSTANDARD LVCMOS15 [get_ports cpu_reset_i]

## GPIO User LEDs (8 bits)
set_property PACKAGE_PIN AB8 [get_ports {gpio_led_o[0]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_led_o[0]}]
set_property PACKAGE_PIN AA8 [get_ports {gpio_led_o[1]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_led_o[1]}]
set_property PACKAGE_PIN AC9 [get_ports {gpio_led_o[2]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_led_o[2]}]
set_property PACKAGE_PIN AB9 [get_ports {gpio_led_o[3]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_led_o[3]}]
set_property PACKAGE_PIN AE26 [get_ports {gpio_led_o[4]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_led_o[4]}]
set_property PACKAGE_PIN G19 [get_ports {gpio_led_o[5]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_led_o[5]}]
set_property PACKAGE_PIN E18 [get_ports {gpio_led_o[6]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_led_o[6]}]
set_property PACKAGE_PIN F16 [get_ports {gpio_led_o[7]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_led_o[7]}]

## GPIO DIP Switches (4 bits)
set_property PACKAGE_PIN Y29 [get_ports {gpio_sw_i[0]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_sw_i[0]}]
set_property PACKAGE_PIN W29 [get_ports {gpio_sw_i[1]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_sw_i[1]}]
set_property PACKAGE_PIN AA28 [get_ports {gpio_sw_i[2]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_sw_i[2]}]
set_property PACKAGE_PIN Y28 [get_ports {gpio_sw_i[3]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_sw_i[3]}]

## GPIO Push Buttons (5 bits)
set_property PACKAGE_PIN G12 [get_ports {gpio_btn_i[0]}]
set_property IOSTANDARD LVCMOS25 [get_ports {gpio_btn_i[0]}]
set_property PACKAGE_PIN AB12 [get_ports {gpio_btn_i[1]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_btn_i[1]}]
set_property PACKAGE_PIN AA12 [get_ports {gpio_btn_i[2]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_btn_i[2]}]
set_property PACKAGE_PIN AG5 [get_ports {gpio_btn_i[3]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_btn_i[3]}]
set_property PACKAGE_PIN AC6 [get_ports {gpio_btn_i[4]}]
set_property IOSTANDARD LVCMOS15 [get_ports {gpio_btn_i[4]}]

## UART
set_property PACKAGE_PIN K24 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS25 [get_ports uart_tx_o]
set_property PACKAGE_PIN M19 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS25 [get_ports uart_rx_i]
