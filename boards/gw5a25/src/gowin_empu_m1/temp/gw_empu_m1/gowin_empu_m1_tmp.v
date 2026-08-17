//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12.01
//IP Version: 2.1
//Part Number: GW5A-LV25MG121NES
//Device: GW5A-25
//Device Version: A
//Created Time: Mon Aug 17 12:13:54 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	Gowin_EMPU_M1_Top your_instance_name(
		.LOCKUP(LOCKUP), //output LOCKUP
		.HALTED(HALTED), //output HALTED
		.GPIO(GPIO), //inout [15:0] GPIO
		.JTAG_7(JTAG_7), //inout JTAG_7
		.JTAG_9(JTAG_9), //inout JTAG_9
		.UART0RXD(UART0RXD), //input UART0RXD
		.UART0TXD(UART0TXD), //output UART0TXD
		.HCLK(HCLK), //input HCLK
		.hwRstn(hwRstn) //input hwRstn
	);

//--------Copy end-------------------
