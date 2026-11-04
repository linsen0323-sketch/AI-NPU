# Zynq-7020 Navigator V2, STATIC Vivado XDC - NO Tcl foreach/proc/if.
# Corrects prior Designutils 20-1307 warnings, which silently skipped the pin assignment loops.
create_clock -name sys_clk -period 20.000 [get_ports sys_clk]
create_clock -name cam_pclk -period 11.905 [get_ports cam_pclk]

# Main board pins
set_property PACKAGE_PIN U18 [get_ports {sys_clk}]
set_property PACKAGE_PIN N16 [get_ports {sys_rst_n}]
set_property PACKAGE_PIN W14 [get_ports {cam_pclk}]
set_property PACKAGE_PIN U12 [get_ports {cam_vsync}]
set_property PACKAGE_PIN T12 [get_ports {cam_href}]
set_property PACKAGE_PIN W15 [get_ports {cam_xclk}]
set_property PACKAGE_PIN P14 [get_ports {cam_rst_n}]
set_property PACKAGE_PIN V15 [get_ports {cam_pwdn}]
set_property PACKAGE_PIN T10 [get_ports {cam_scl}]
set_property PACKAGE_PIN T11 [get_ports {cam_sda}]

# Camera DVP D[7:0], explicitly enumerated (not in a Tcl foreach):
set_property PACKAGE_PIN R14 [get_ports {cam_data[0]}]
set_property PACKAGE_PIN U13 [get_ports {cam_data[1]}]
set_property PACKAGE_PIN V13 [get_ports {cam_data[2]}]
set_property PACKAGE_PIN U15 [get_ports {cam_data[3]}]
set_property PACKAGE_PIN U14 [get_ports {cam_data[4]}]
set_property PACKAGE_PIN W13 [get_ports {cam_data[5]}]
set_property PACKAGE_PIN V12 [get_ports {cam_data[6]}]
set_property PACKAGE_PIN Y14 [get_ports {cam_data[7]}]

set_property IOSTANDARD LVCMOS33 [get_ports {sys_clk sys_rst_n cam_pclk cam_vsync cam_href cam_xclk cam_rst_n cam_pwdn cam_scl cam_sda}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_data*}]
set_property PULLUP TRUE [get_ports {sys_rst_n cam_scl cam_sda}]
set_property DRIVE 8 [get_ports {cam_xclk cam_rst_n cam_pwdn cam_scl cam_sda}]
set_property SLEW FAST [get_ports cam_xclk]
set_property SLEW SLOW [get_ports {cam_rst_n cam_pwdn cam_scl cam_sda}]

# W14 is not a dedicated clock pin on this baseboard; this permits routing but does not waive timing.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cam_pclk_IBUF]

# HDMI TMDS pins, explicitly enumerated:
set_property PACKAGE_PIN G19 [get_ports {tmds_data_p[0]}]
set_property PACKAGE_PIN G20 [get_ports {tmds_data_n[0]}]
set_property PACKAGE_PIN K19 [get_ports {tmds_data_p[1]}]
set_property PACKAGE_PIN J19 [get_ports {tmds_data_n[1]}]
set_property PACKAGE_PIN J20 [get_ports {tmds_data_p[2]}]
set_property PACKAGE_PIN H20 [get_ports {tmds_data_n[2]}]
set_property PACKAGE_PIN J18 [get_ports {tmds_clk_p}]
set_property PACKAGE_PIN H18 [get_ports {tmds_clk_n}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_clk_p tmds_clk_n}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_p* tmds_data_n*}]

# DVP AC timing remains an ENGINEERING ESTIMATE, NOT VERIFIED sensor-board timing.
# Source clock data changes near PCLK falling edge; FPGA samples rising edge.
set_input_delay -clock [get_clocks cam_pclk] -clock_fall -min -0.500 [get_ports {cam_data* cam_href cam_vsync}]
set_input_delay -clock [get_clocks cam_pclk] -clock_fall -max 3.000 [get_ports {cam_data* cam_href cam_vsync}]
set_clock_uncertainty 0.200 [get_clocks cam_pclk]

# Reset button and bidirectional low-speed SCCB are asynchronous, not DVP pixel data.
set_false_path -from [get_ports sys_rst_n]
set_false_path -from [get_ports {cam_scl cam_sda}]

# Mechanical user keys, baseboard V3.9: 10k pullup, pressed = 0.
# N16 remains reset only. Synchronizers are in ai_preprocess_top (AXI clock).
set_property PACKAGE_PIN L14 [get_ports {pl_keys_n[0]}]
set_property PACKAGE_PIN K16 [get_ports {pl_keys_n[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {pl_keys_n[*]}]
set_property PULLUP TRUE [get_ports {pl_keys_n[*]}]
set_false_path -from [get_ports {pl_keys_n[*]}] -to [get_cells -hier -filter {NAME =~ *key_meta_reg*}]
