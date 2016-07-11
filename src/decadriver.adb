-------------------------------------------------------------------------------
--  Copyright (c) 2016 Daniel King
--
--  Permission is hereby granted, free of charge, to any person obtaining a
--  copy of this software and associated documentation files (the "Software"),
--  to deal in the Software without restriction, including without limitation
--  the rights to use, copy, modify, merge, publish, distribute, sublicense,
--  and/or sell copies of the Software, and to permit persons to whom the
--  Software is furnished to do so, subject to the following conditions:
--
--  The above copyright notice and this permission notice shall be included in
--  all copies or substantial portions of the Software.
--
--  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
--  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--  DEALINGS IN THE SOFTWARE.
-------------------------------------------------------------------------------

with DW1000.Constants;
with DW1000.Reception_Quality; use DW1000.Reception_Quality;
with DW1000.Registers;
with DW1000.Register_Driver;
with Interfaces;               use Interfaces;

package body DecaDriver
with SPARK_Mode => On
is
   Default_SFD_Timeout : constant DW1000.Driver.SFD_Timeout_Number := 16#1041#;

   LDE_Replica_Coeffs : constant
     array (DW1000.Driver.Preamble_Code_Number) of Bits_16
       := (1  => Bits_16 (0.35 * 2**16),
           2  => Bits_16 (0.35 * 2**16),
           3  => Bits_16 (0.32 * 2**16),
           4  => Bits_16 (0.26 * 2**16),
           5  => Bits_16 (0.27 * 2**16),
           6  => Bits_16 (0.18 * 2**16),
           7  => Bits_16 (0.50 * 2**16),
           8  => Bits_16 (0.32 * 2**16),
           9  => Bits_16 (0.16 * 2**16),
           10 => Bits_16 (0.20 * 2**16),
           11 => Bits_16 (0.23 * 2**16),
           12 => Bits_16 (0.24 * 2**16),
           13 => Bits_16 (0.23 * 2**16),
           14 => Bits_16 (0.21 * 2**16),
           15 => Bits_16 (0.27 * 2**16),
           16 => Bits_16 (0.21 * 2**16),
           17 => Bits_16 (0.20 * 2**16),
           18 => Bits_16 (0.21 * 2**16),
           19 => Bits_16 (0.21 * 2**16),
           20 => Bits_16 (0.28 * 2**16),
           21 => Bits_16 (0.23 * 2**16),
           22 => Bits_16 (0.22 * 2**16),
           23 => Bits_16 (0.19 * 2**16),
           24 => Bits_16 (0.22 * 2**16));


   function Receive_Timestamp (Frame_Info : in Frame_Info_Type)
                               return Fine_System_Time
   is
   begin
      return To_Fine_System_Time (Frame_Info.RX_TIME_Reg.RX_STAMP);
   end Receive_Timestamp;


   function Receive_Signal_Power (Frame_Info : in Frame_Info_Type)
                                  return Float
   is
      RXBR       : Bits_2;
      SFD_LENGTH : Bits_8;
      RXPACC     : Bits_12;
   begin
      RXBR := Frame_Info.RX_FINFO_Reg.RXBR;
      if RXBR = 2#11# then --  Detect reserved value
         RXBR := 2#10#; --  default to 6.8 Mbps
      end if;

      SFD_LENGTH := Frame_Info.SFD_LENGTH;
      if not (SFD_LENGTH in 8 | 16) then
         SFD_LENGTH := 8; --  default to length 8
      end if;

      RXPACC := Adjust_RXPACC
        (RXPACC           => Frame_Info.RX_FINFO_Reg.RXPACC,
         RXPACC_NOSAT     => Frame_Info.RXPACC_NOSAT_Reg.RXPACC_NOSAT,
         RXBR             => RXBR,
         SFD_LENGTH       => SFD_LENGTH,
         Non_Standard_SFD => Frame_Info.Non_Standard_SFD);

      return Receive_Signal_Power
        (Use_16MHz_PRF => Frame_Info.RX_FINFO_Reg.RXPRF = 2#10#,
         RXPACC        => RXPACC,
         CIR_PWR       => Frame_Info.RX_FQUAL_Reg.CIR_PWR);
   end Receive_Signal_Power;


   function First_Path_Signal_Power (Frame_Info : in Frame_Info_Type)
                                     return Float
   is
      RXBR       : Bits_2;
      SFD_LENGTH : Bits_8;
      RXPACC     : Bits_12;
   begin
      RXBR := Frame_Info.RX_FINFO_Reg.RXBR;
      if RXBR = 2#11# then --  Detect reserved value
         RXBR := 2#10#; --  default to 6.8 Mbps
      end if;

      SFD_LENGTH := Frame_Info.SFD_LENGTH;
      if not (SFD_LENGTH in 8 | 16) then
         SFD_LENGTH := 8; --  default to length 8
      end if;

      RXPACC := Adjust_RXPACC
        (RXPACC           => Frame_Info.RX_FINFO_Reg.RXPACC,
         RXPACC_NOSAT     => Frame_Info.RXPACC_NOSAT_Reg.RXPACC_NOSAT,
         RXBR             => RXBR,
         SFD_LENGTH       => SFD_LENGTH,
         Non_Standard_SFD => Frame_Info.Non_Standard_SFD);

      return First_Path_Signal_Power
        (Use_16MHz_PRF => Frame_Info.RX_FINFO_Reg.RXPRF = 2#10#,
         F1            => Frame_Info.RX_TIME_Reg.FP_AMPL1,
         F2            => Frame_Info.RX_FQUAL_Reg.FP_AMPL2,
         F3            => Frame_Info.RX_FQUAL_Reg.FP_AMPL3,
         RXPACC        => RXPACC);
   end First_Path_Signal_Power;


   protected body Receiver_Type
   is
      entry Wait (Frame      : in out DW1000.Types.Byte_Array;
                  Size       :    out Frame_Length_Number;
                  Frame_Info :    out Frame_Info_Type;
                  Error      :    out Rx_Errors;
                  Overrun    :    out Boolean)
        when Frame_Ready
      is
      begin
         Size       := Frame_Queue (Queue_Head).Size;
         Frame_Info := Frame_Queue (Queue_Head).Frame_Info;
         Error      := Frame_Queue (Queue_Head).Error;
         Overrun    := Frame_Queue (Queue_Head).Overrun;

         if Error = No_Error then
            if Frame'Length >= Size then
               Frame (Frame'First .. Frame'First + Integer (Size - 1))
                 := Frame_Queue (Queue_Head).Frame (1 .. Size);

            else
               Frame := Frame_Queue (Queue_Head).Frame (1 .. Frame'Length);

            end if;
         end if;

         Queue_Head  := Queue_Head + 1;
         Rx_Count    := Rx_Count - 1;
         Frame_Ready := Rx_Count > 0;

      end Wait;

      function Pending_Frames_Count return Natural
      is
      begin
         return Rx_Count;
      end Pending_Frames_Count;

      procedure Discard_Pending_Frames
      is
      begin
         Rx_Count := 0;
      end Discard_Pending_Frames;

      procedure Set_Frame_Filtering_Enabled (Enabled : in Boolean)
      is
      begin
         DW1000.Driver.Set_Frame_Filtering_Enabled (Enabled);
      end Set_Frame_Filtering_Enabled;

      procedure Configure_Frame_Filtering (Behave_As_Coordinator : in Boolean;
                                           Allow_Beacon_Frame    : in Boolean;
                                           Allow_Data_Frame      : in Boolean;
                                           Allow_Ack_Frame       : in Boolean;
                                           Allow_MAC_Cmd_Frame   : in Boolean;
                                           Allow_Reserved_Frame  : in Boolean;
                                           Allow_Frame_Type_4    : in Boolean;
                                           Allow_Frame_Type_5    : in Boolean)
      is
      begin
         DW1000.Driver.Configure_Frame_Filtering
           (Behave_As_Coordinator => Behave_As_Coordinator,
            Allow_Beacon_Frame    => Allow_Beacon_Frame,
            Allow_Data_Frame      => Allow_Data_Frame,
            Allow_Ack_Frame       => Allow_Ack_Frame,
            Allow_MAC_Cmd_Frame   => Allow_MAC_Cmd_Frame,
            Allow_Reserved_Frame  => Allow_Reserved_Frame,
            Allow_Frame_Type_4    => Allow_Frame_Type_4,
            Allow_Frame_Type_5    => Allow_Frame_Type_5);
      end Configure_Frame_Filtering;

      procedure Set_Rx_Double_Buffer (Enabled : in Boolean)
      is
      begin
         DW1000.Driver.Set_Rx_Double_Buffer (Enabled);
      end Set_Rx_Double_Buffer;

      procedure Set_Rx_Auto_Reenable (Enabled : in Boolean)
      is
      begin
         DW1000.Driver.Set_Auto_Rx_Reenable (Enabled);
      end Set_Rx_Auto_Reenable;

      procedure Set_Delayed_Rx_Time(Time : in Coarse_System_Time)
      is
      begin
         DW1000.Driver.Set_Delayed_Tx_Rx_Time (Time);
      end Set_Delayed_Rx_Time;

      procedure Start_Rx_Immediate
      is
      begin
         DW1000.Driver.Start_Rx_Immediate;
      end Start_Rx_Immediate;

      procedure Start_Rx_Delayed (Result  : out Result_Type)
      is
      begin
         DW1000.Driver.Start_Rx_Delayed (Result => Result);
      end Start_Rx_Delayed;

      procedure Notify_Frame_Received
      is
         RX_FINFO_Reg : DW1000.Register_Types.RX_FINFO_Type;

         Frame_Length : Natural;
         Next_Idx     : Rx_Frame_Queue_Index;

      begin
         --  Read the frame length from the DW1000
         DW1000.Registers.RX_FINFO.Read (RX_FINFO_Reg);
         Frame_Length := Natural (RX_FINFO_Reg.RXFLEN) +
                         Natural (RX_FINFO_Reg.RXFLE) * 2**7;

         pragma Assert (Frame_Length <= DW1000.Constants.RX_BUFFER_Length);

         if Frame_Length > 0 then
            if Rx_Count >= Frame_Queue'Length then
               Overrun_Occurred := True;

            else
               Next_Idx := Queue_Head + Rx_Frame_Queue_Index (Rx_Count);

               Rx_Count := Rx_Count + 1;

               DW1000.Register_Driver.Read_Register
                 (Register_ID => DW1000.Registers.RX_BUFFER_Reg_ID,
                  Sub_Address => 0,
                  Data        =>
                    Frame_Queue (Next_Idx).Frame (1 .. Frame_Length));

               Frame_Queue (Next_Idx).Size    := Frame_Length;
               Frame_Queue (Next_Idx).Error   := No_Error;
               Frame_Queue (Next_Idx).Overrun := Overrun_Occurred;

               Overrun_Occurred := False;

               DW1000.Registers.RX_FINFO.Read
                 (Frame_Queue (Next_Idx).Frame_Info.RX_FINFO_Reg);

               DW1000.Registers.RX_FQUAL.Read
                 (Frame_Queue (Next_Idx).Frame_Info.RX_FQUAL_Reg);

               DW1000.Registers.RX_TIME.Read
                 (Frame_Queue (Next_Idx).Frame_Info.RX_TIME_Reg);

               declare
                  Byte : Byte_Array (1 .. 1);
               begin
                  --  Don't read the entire USR_SFD register. We only need to
                  --  read the first byte (the SFD_LENGTH field).
                  DW1000.Register_Driver.Read_Register
                    (Register_ID => DW1000.Registers.USR_SFD_Reg_ID,
                     Sub_Address => 0,
                     Data        => Byte);
                  Frame_Queue (Next_Idx).Frame_Info.SFD_LENGTH := Byte (1);
               end;

               --  Check the CHAN_CTRL register to determine whether or not a
               --  non-standard SFD is being used.
               declare
                  CHAN_CTRL_Reg : CHAN_CTRL_Type;
               begin
                  DW1000.Registers.CHAN_CTRL.Read (CHAN_CTRL_Reg);
                  Frame_Queue (Next_Idx).Frame_Info.Non_Standard_SFD
                    := CHAN_CTRL_Reg.DWSFD = 1;
               end;
            end if;

            Frame_Ready := True;
         end if;

         DW1000.Driver.Toggle_Host_Side_Rx_Buffer_Pointer;
      end Notify_Frame_Received;

      procedure Notify_Receive_Error (Error : in Rx_Errors)
      is
         Next_Idx     : Rx_Frame_Queue_Index;

      begin
         if Rx_Count >= Frame_Queue'Length then
            Overrun_Occurred := True;

         else
            Next_Idx := Queue_Head + Rx_Frame_Queue_Index (Rx_Count);

            Rx_Count := Rx_Count + 1;

            Frame_Queue (Next_Idx).Size    := 0;
            Frame_Queue (Next_Idx).Error   := Error;
            Frame_Queue (Next_Idx).Overrun := Overrun_Occurred;
            Overrun_Occurred := False;
         end if;

         Frame_Ready := True;
      end Notify_Receive_Error;

   end Receiver_Type;


   protected body Transmitter_Type
   is

      entry Wait_For_Tx_Complete
      with SPARK_Mode => Off --  Workaround for "statement has no effect" below
        when Tx_Idle
      is
      begin
         null;
      end Wait_For_Tx_Complete;

      function Is_Tx_Complete return Boolean
      is
      begin
         return Tx_Idle;
      end Is_Tx_Complete;

      procedure Configure_Tx_Power (Config : Tx_Power_Config_Type)
      is
      begin
         if Config.Smart_Tx_Power_Enabled then
            DW1000.Driver.Configure_Smart_Tx_Power
              (Boost_Normal => Config.Boost_Normal,
               Boost_500us  => Config.Boost_500us,
               Boost_250us  => Config.Boost_250us,
               Boost_125us  => Config.Boost_125us);
         else
            DW1000.Driver.Configure_Manual_Tx_Power
              (Boost_SHR => Config.Boost_SHR,
               Boost_PHR => Config.Boost_PHR);
         end if;
      end Configure_Tx_Power;

      procedure Set_Tx_Data (Data   : in DW1000.Types.Byte_Array;
                             Offset : in Natural)
      is
      begin
         DW1000.Driver.Set_Tx_Data (Data   => Data,
                                    Offset => Offset);
      end Set_Tx_Data;

      procedure Set_Tx_Frame_Length (Length : in Natural;
                                     Offset : in Natural)
      is
      begin
         DW1000.Driver.Set_Tx_Frame_Length (Length => Length,
                                            Offset => Offset);
      end Set_Tx_Frame_Length;

      procedure Set_Delayed_Tx_Time(Time : in Coarse_System_Time)
      is
      begin
         DW1000.Driver.Set_Delayed_Tx_Rx_Time (Time);
      end Set_Delayed_Tx_Time;

      procedure Start_Tx_Immediate (Rx_After_Tx : in     Boolean)
      is
      begin
         DW1000.Driver.Start_Tx_Immediate (Rx_After_Tx);
         Tx_Idle := False;
      end Start_Tx_Immediate;

      procedure Start_Tx_Delayed
        (Rx_After_Tx : in     Boolean;
         Result      :    out DW1000.Driver.Result_Type)
      is
      begin
         DW1000.Driver.Start_Tx_Delayed (Rx_After_Tx => Rx_After_Tx,
                                         Result      => Result);

         Tx_Idle := not (Result = DW1000.Driver.Success);
      end Start_Tx_Delayed;

      procedure Notify_Tx_Complete
      is
      begin
         Tx_Idle := True;
      end Notify_Tx_Complete;

   end Transmitter_Type;


   --  Driver_Type body

   protected body Driver_Type
   is

      procedure Initialize (Load_Antenna_Delay   : in Boolean;
                            Load_XTAL_Trim       : in Boolean;
                            Load_Tx_Power_Levels : in Boolean;
                            Load_UCode_From_ROM  : in Boolean)
      is
         Word : Bits_32;

         PMSC_CTRL1_Reg : DW1000.Register_Types.PMSC_CTRL1_Type;
         SYS_MASK_Reg   : DW1000.Register_Types.SYS_MASK_Type;

      begin

         DW1000.Driver.Enable_Clocks (DW1000.Driver.Force_Sys_XTI);

         DW1000.Driver.Read_OTP (DW1000.Constants.OTP_ADDR_CHIP_ID, Part_ID);
         DW1000.Driver.Read_OTP (DW1000.Constants.OTP_ADDR_LOT_ID, Lot_ID);

         if Load_Antenna_Delay then
            DW1000.Driver.Read_OTP (DW1000.Constants.OTP_ADDR_ANTENNA_DELAY,
                                    Word);

            -- High 16 bits are the antenna delay with a 64 MHz PRF.
            -- Low 16 bits are the antenna delay with a 16 MHz PRF.
            Antenna_Delay_PRF_16 := Bits_16 (Word and 16#FFFF#);
            Word := Shift_Right (Word, 16);
            Antenna_Delay_PRF_64 := Bits_16 (Word and 16#FFFF#);
         else
            Antenna_Delay_PRF_16 := 0;
            Antenna_Delay_PRF_64 := 0;
         end if;

         if Load_XTAL_Trim then
            DW1000.Driver.Read_OTP (DW1000.Constants.OTP_ADDR_XTAL_TRIM, Word);
            XTAL_Trim := Bits_5 (Word and 2#1_1111#);
         else
            XTAL_Trim := 2#1_0000#; -- Set to midpoint
         end if;

         if Load_UCode_From_ROM then
            DW1000.Driver.Load_LDE_From_ROM;

         else
            -- Should disable LDERUN bit, since the LDE isn't loaded.
            DW1000.Registers.PMSC_CTRL1.Read (PMSC_CTRL1_Reg);
            PMSC_CTRL1_Reg.LDERUNE := 0;
            DW1000.Registers.PMSC_CTRL1.Write (PMSC_CTRL1_Reg);
         end if;

         DW1000.Driver.Enable_Clocks (DW1000.Driver.Force_Sys_PLL);
         DW1000.Driver.Enable_Clocks (DW1000.Driver.Enable_All_Seq);

         --  Store a local copy of the SYS_CFG register
         DW1000.Registers.SYS_CFG.Read (SYS_CFG_Reg);

         --  Configure IRQs
         DW1000.Registers.SYS_MASK.Read (SYS_MASK_Reg);
         SYS_MASK_Reg.MRXSFDTO := 1;
         SYS_MASK_Reg.MRXPHE   := 1;
         SYS_MASK_Reg.MRXRFSL  := 1;
         SYS_MASK_Reg.MRXFCE   := 1;
         SYS_MASK_Reg.MRXDFR   := 1; --  Always detect frame received
         SYS_MASK_Reg.MTXFRS   := 1; --  Always detect frame sent
         DW1000.Registers.SYS_MASK.Write (SYS_MASK_Reg);

         Detect_Frame_Timeout := True;
         Detect_SFD_Timeout   := True;
         Detect_PHR_Error     := True;
         Detect_RS_Error      := True;
         Detect_FCS_Error     := True;

      end Initialize;



      procedure Configure (Config : in Configuration_Type)
      is
         LDE_REPC_Reg  : DW1000.Register_Types.LDE_REPC_Type;

         SFD_Timeout : DW1000.Driver.SFD_Timeout_Number;

      begin

         LDE_REPC_Reg.LDE_REPC := LDE_Replica_Coeffs (Config.Rx_Preamble_Code);

         --  110 kbps data rate has special handling
         if Config.Data_Rate = DW1000.Driver.Data_Rate_110k then
            SYS_CFG_Reg.RXM110K := 1;

            LDE_REPC_Reg.LDE_REPC := LDE_REPC_Reg.LDE_REPC / 8;

         else
            SYS_CFG_Reg.RXM110K := 0;
         end if;

         Long_Frames := Config.PHR_Mode = DW1000.Driver.Extended_Frames;
         SYS_CFG_Reg.PHR_MODE :=
           Bits_2 (DW1000.Driver.Physical_Header_Modes'Pos (Config.PHR_Mode));

         DW1000.Registers.SYS_CFG.Write (SYS_CFG_Reg);
         DW1000.Registers.LDE_REPC.Write (LDE_REPC_Reg);

         DW1000.Driver.Configure_LDE (Config.PRF);
         DW1000.Driver.Configure_PLL (Config.Channel);
         DW1000.Driver.Configure_RF (Config.Channel);

         --  Don't allow a zero SFD timeout
         SFD_Timeout := (if Config.SFD_Timeout = 0
                         then Default_SFD_Timeout
                         else Config.SFD_Timeout);

         DW1000.Driver.Configure_DRX
           (PRF                => Config.PRF,
            Data_Rate          => Config.Data_Rate,
            Tx_Preamble_Length => Config.Tx_Preamble_Length,
            PAC                => Config.Tx_PAC,
            SFD_Timeout        => SFD_Timeout,
            Nonstandard_SFD    => Config.Use_Nonstandard_SFD);

         DW1000.Driver.Configure_AGC (Config.PRF);

         --  If a non-std SFD is used then the SFD length must be programmed
         --  for the DecaWave SFD, based on the data rate.
         if Config.Use_Nonstandard_SFD then
            Configure_Nonstandard_SFD_Length (Config.Data_Rate);
         end if;

         --  Configure the channel, Rx PRF, non-std SFD, and preamble codes
         DW1000.Registers.CHAN_CTRL.Write
           (DW1000.Register_Types.CHAN_CTRL_Type'
              (TX_CHAN  => Bits_4 (Config.Channel),
               RX_CHAN  => Bits_4 (Config.Channel),
               DWSFD    => (if Config.Use_Nonstandard_SFD then 1 else 0),
               RXPRF    => (if Config.PRF = PRF_16MHz then 2#01# else 2#10#),
               TNSSFD   => (if Config.Use_Nonstandard_SFD then 1 else 0),
               RNSSFD   => (if Config.Use_Nonstandard_SFD then 1 else 0),
               TX_PCODE => Bits_5 (Config.Tx_Preamble_Code),
               RX_PCODE => Bits_5 (Config.Rx_Preamble_Code),
               Reserved => 0));

         --  Set the Tx frame control (transmit data rate, PRF, ranging bit)
         DW1000.Registers.TX_FCTRL.Write
           (DW1000.Register_Types.TX_FCTRL_Type'
              (TFLEN    => 0,
               TFLE     => 0,
               R        => 0,
               TXBR     => Bits_2 (Data_Rates'Pos (Config.Data_Rate)),
               TR       => 1,
               TXPRF    => (if Config.PRF = PRF_16MHz then 2#01# else 2#10#),
               TXPSR    =>
                 (case Config.Tx_Preamble_Length is
                     when PLEN_64 | PLEN_128 | PLEN_256 | PLEN_512 => 2#01#,
                     when PLEN_1024 | PLEN_1536 | PLEN_2048        => 2#10#,
                     when others                                   => 2#11#),
               PE       =>
                 (case Config.Tx_Preamble_Length is
                     when PLEN_64 | PLEN_1024 | PLEN_4096 => 2#00#,
                     when PLEN_128 | PLEN_1536            => 2#01#,
                     when PLEN_256 | PLEN_2048            => 2#10#,
                     when others                          => 2#11#),
               TXBOFFS  => 0,
               IFSDELAY => 0));

         --  Load the crystal trim (if requested)
         if Use_OTP_XTAL_Trim then
            DW1000.Driver.Set_XTAL_Trim (XTAL_Trim);
         end if;

         --  Load the antenna delay (if requested)
         if Use_OTP_Antenna_Delay then
            if Config.PRF = PRF_16MHz then
               DW1000.Driver.Write_Tx_Antenna_Delay (Antenna_Delay_PRF_16);
               DW1000.Driver.Write_Rx_Antenna_Delay (Antenna_Delay_PRF_16);
            else
               DW1000.Driver.Write_Tx_Antenna_Delay (Antenna_Delay_PRF_64);
               DW1000.Driver.Write_Rx_Antenna_Delay (Antenna_Delay_PRF_64);
            end if;
         end if;

         --  Configure transmit power levels


      end Configure;

      procedure Configure_Errors (Frame_Timeout : in Boolean;
                                  SFD_Timeout   : in Boolean;
                                  PHR_Error     : in Boolean;
                                  RS_Error      : in Boolean;
                                  FCS_Error     : in Boolean)
      is
         SYS_MASK_Reg : DW1000.Register_Types.SYS_MASK_Type;

      begin
         --  Configure which interrupts are enabled
         DW1000.Registers.SYS_MASK.Read (SYS_MASK_Reg);
         SYS_MASK_Reg.MRXRFTO  := (if Frame_Timeout then 1 else 0);
         SYS_MASK_Reg.MRXSFDTO := (if SFD_Timeout   then 1 else 0);
         SYS_MASK_Reg.MRXPHE   := (if PHR_Error     then 1 else 0);
         SYS_MASK_Reg.MRXRFSL  := (if RS_Error      then 1 else 0);
         SYS_MASK_Reg.MRXFCE   := (if FCS_Error     then 1 else 0);
         DW1000.Registers.SYS_MASK.Write (SYS_MASK_Reg);

         Detect_Frame_Timeout := Frame_Timeout;
         Detect_SFD_Timeout   := SFD_Timeout;
         Detect_PHR_Error     := PHR_Error;
         Detect_RS_Error      := RS_Error;
         Detect_FCS_Error     := FCS_Error;
      end Configure_Errors;

      procedure Force_Tx_Rx_Off
      is
      begin
         DW1000.Driver.Force_Tx_Rx_Off;
      end Force_Tx_Rx_Off;

      function Get_Part_ID return Bits_32
      is
      begin
         return Part_ID;
      end Get_Part_ID;

      function Get_Lot_ID  return Bits_32
      is
      begin
         return Lot_ID;
      end Get_Lot_ID;

      function PHR_Mode return DW1000.Driver.Physical_Header_Modes
      is
      begin
         if Long_Frames then
            return Extended_Frames;
         else
            return Standard_Frames;
         end if;
      end PHR_Mode;

      procedure DW1000_IRQ
      is
         SYS_STATUS_Reg : DW1000.Register_Types.SYS_STATUS_Type;

         SYS_STATUS_Clear : DW1000.Register_Types.SYS_STATUS_Type
           := (IRQS       => 0,
               CPLOCK     => 0,
               ESYNCR     => 0,
               AAT        => 0,
               TXFRB      => 0,
               TXPRS      => 0,
               TXPHS      => 0,
               TXFRS      => 0,
               RXPRD      => 0,
               RXSFDD     => 0,
               LDEDONE    => 0,
               RXPHD      => 0,
               RXPHE      => 0,
               RXDFR      => 0,
               RXFCG      => 0,
               RXFCE      => 0,
               RXRFSL     => 0,
               RXRFTO     => 0,
               LDEERR     => 0,
               RXOVRR     => 0,
               RXPTO      => 0,
               GPIOIRQ    => 0,
               SLP2INIT   => 0,
               RFPLL_LL   => 0,
               CLKPLL_LL  => 0,
               RXSFDTO    => 0,
               HPDWARN    => 0,
               TXBERR     => 0,
               AFFREJ     => 0,
               HSRBP      => 0,
               ICRBP      => 0,
               RXRSCS     => 0,
               RXPREJ     => 0,
               TXPUTE     => 0,
               Reserved_1 => 0,
               Reserved_2 => 0);

      begin
         DW1000.BSP.Acknowledge_DW1000_IRQ;

         DW1000.Registers.SYS_STATUS.Read (SYS_STATUS_Reg);

         if SYS_STATUS_Reg.RXRFTO = 1 then
            if Detect_Frame_Timeout then
               Receiver.Notify_Receive_Error (Frame_Timeout);
            end if;
            SYS_STATUS_Clear.RXRFTO := 1;
         end if;

         if SYS_STATUS_Reg.RXSFDTO = 1 then
            if Detect_SFD_Timeout then
               Receiver.Notify_Receive_Error (SFD_Timeout);
            end if;
            SYS_STATUS_Clear.RXSFDTO := 1;
         end if;

         if SYS_STATUS_Reg.RXRFSL = 1 then
            if Detect_RS_Error then
               Receiver.Notify_Receive_Error (RS_Error);
            end if;
            SYS_STATUS_Clear.RXRFSL := 1;
         end if;

         if SYS_STATUS_Reg.RXDFR = 1 then

            if SYS_STATUS_Reg.RXFCG = 1 then
               Receiver.Notify_Frame_Received;
               SYS_STATUS_Clear.RXFCG := 1;

            elsif SYS_STATUS_Reg.RXFCE = 1 then
               if Detect_FCS_Error then
                  Receiver.Notify_Receive_Error (FCS_Error);
               end if;
               SYS_STATUS_Clear.RXFCE := 1;

            end if;

            --  Clear RX flags
            SYS_STATUS_Clear.RXDFR   := 1;
            SYS_STATUS_Clear.RXPRD   := 1;
            SYS_STATUS_Clear.RXSFDD  := 1;
            SYS_STATUS_Clear.LDEDONE := 1;
            SYS_STATUS_Clear.RXPHD   := 1;
         end if;

         if SYS_STATUS_Reg.TXFRS = 1 then
            --  Frame sent
            Transmitter.Notify_Tx_Complete;

            -- Clear all TX events
            SYS_STATUS_Clear.AAT   := 1;
            SYS_STATUS_Clear.TXFRS := 1;
            SYS_STATUS_Clear.TXFRB := 1;
            SYS_STATUS_Clear.TXPHS := 1;
            SYS_STATUS_Clear.TXPRS := 1;
         end if;

         SYS_STATUS_Clear.AFFREJ := 1;

         --  Clear events that we have seen.
         DW1000.Registers.SYS_STATUS.Write (SYS_STATUS_Clear);

      end DW1000_IRQ;

   end Driver_Type;

end DecaDriver;
