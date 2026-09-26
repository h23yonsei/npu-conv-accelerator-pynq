# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "IFM_ADDR_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "OFM_ADDR_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "WGT_ADDR_W" -parent ${Page_0}


}

proc update_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to update C_S_AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to validate C_S_AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.IFM_ADDR_W { PARAM_VALUE.IFM_ADDR_W } {
	# Procedure called to update IFM_ADDR_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.IFM_ADDR_W { PARAM_VALUE.IFM_ADDR_W } {
	# Procedure called to validate IFM_ADDR_W
	return true
}

proc update_PARAM_VALUE.OFM_ADDR_W { PARAM_VALUE.OFM_ADDR_W } {
	# Procedure called to update OFM_ADDR_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.OFM_ADDR_W { PARAM_VALUE.OFM_ADDR_W } {
	# Procedure called to validate OFM_ADDR_W
	return true
}

proc update_PARAM_VALUE.WGT_ADDR_W { PARAM_VALUE.WGT_ADDR_W } {
	# Procedure called to update WGT_ADDR_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.WGT_ADDR_W { PARAM_VALUE.WGT_ADDR_W } {
	# Procedure called to validate WGT_ADDR_W
	return true
}


proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.IFM_ADDR_W { MODELPARAM_VALUE.IFM_ADDR_W PARAM_VALUE.IFM_ADDR_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.IFM_ADDR_W}] ${MODELPARAM_VALUE.IFM_ADDR_W}
}

proc update_MODELPARAM_VALUE.WGT_ADDR_W { MODELPARAM_VALUE.WGT_ADDR_W PARAM_VALUE.WGT_ADDR_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.WGT_ADDR_W}] ${MODELPARAM_VALUE.WGT_ADDR_W}
}

proc update_MODELPARAM_VALUE.OFM_ADDR_W { MODELPARAM_VALUE.OFM_ADDR_W PARAM_VALUE.OFM_ADDR_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.OFM_ADDR_W}] ${MODELPARAM_VALUE.OFM_ADDR_W}
}

