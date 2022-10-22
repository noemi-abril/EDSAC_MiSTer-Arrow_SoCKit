
module teletype (
   input clk,                                                  /* Clock input */
   
   input [10:0] horizontal_counter,                            /* Get common horizontal and vertical counters from the sync generation block in main module */
   input [10:0] vertical_counter,   
                        
   output wire [7:0] red_out,                                  /* Outputs RGB for the emulated terminal image */
   output wire [7:0] green_out,
   output wire [7:0] blue_out,               
   
   input [4:0] char_in,                                        /* Character received from the EDSAC */
   
   input erase,                                                /* Erase all characters */
   input character_strobe                                      /* Signals the EDSAC has output a character and we need to read and display it */
);
              
              
/* Teletype special characters */

`define  letters                    5'd15
`define  figures                    5'd11
`define  carriage_return            5'd18
`define  line_feed                  5'd24
`define  blank                      5'd20
        
////////////////////  WIRES  //////////////////////
        
wire [11:0] charset_address;                                   /* Address and data of the current character */
wire [15:0] character_line_data;

wire [10:0] current_y, current_x;                              /* Current pixel position relative to visible part of screen */
wire [10:0] visible_x;   

wire [7:0] fiodec_charcode;                                    /* Character code to look up in ROM */
wire [10:0] fb_rdaddress;                                      /* Framebuffer read address */


//////////////////  REGISTERS  ////////////////////

reg  [15:0] character_line_latch;                              /* Contains a 16-column pixel line used for drawing a character */

reg  [10:0] fb_wraddress;                                      /* For reading and writing to framebuffer ram */
reg  [7:0] fb_wdata;
reg  [0:0] fb_strobe_in;

reg [7:0] pixel_out, bg_out;                                   /* Current pixel intensity and output bitmask */
reg [5:0] reg_char_in;                                         /* Character we received which needs printing */
         
reg [5:0] char_x = 6'b1;                                       /* Current framebuffer position */
reg [4:0] char_y;
 
reg current_case = 1'b0;                                       /* 0 = letters, 1 = figures */
                                                
reg prev_typewriter_strobe_in,                                 /* Used for detecting positive strobe edge */
    prev_prev_typewriter_strobe_in;

reg edsac_strobe_in;                                           /* Positive strobe edge of incoming characters is stored here */
reg inside_visible_area;                                       /* Indicates if current plot position lies within visible area */
reg is_cursor_over_hole,                                       /* Tracks where the holes and tears are for the perforated continuous paper should be drawn */
    is_dashed_line;


/////////////////  ASSIGNMENTS  ///////////////////

/* Screen is divided into a 64 x 32 pixel matrix, and each field contains one character. To store this data, a 2048 byte RAM is instantiated. 
As lines are drawn for each frame, the read address is changed when the horizontal counter "jumps" from one grid element to the next. 
Each character is then looked up in the ROM, depending on the value read and the grid element line number we are currently plotting. */ 

assign fb_rdaddress = { current_y[9:5] + char_y + 4'd11, current_x[9:4] };        
assign charset_address = { 1'b0, fiodec_charcode[5:0], current_y[4:0] };               


/* RGB output, black if it's outside the drawing area, representing a "hole" in the paper or perforated line. Otherwise, output pixel but
bitmask the red and blue channels with bg_out (enabling the row background to be green) */

assign red_out   = inside_visible_area && ~is_cursor_over_hole && ~is_dashed_line ? pixel_out & bg_out : 8'b0;
assign green_out = inside_visible_area && ~is_cursor_over_hole && ~is_dashed_line ? pixel_out : 8'b0;          
assign blue_out  = inside_visible_area && ~is_cursor_over_hole && ~is_dashed_line ? pixel_out & bg_out : 8'b0;
                   
                   
/* Current pixel position counters, relative to the beginning of emulated printout paper */                  
/* 1280x720 @ 60Hz  74.180, 1280, 1390, 1430, 1650, 720, 725, 730, 750 */

`define   h_line_timing          11'd1280
`define   v_line_timing          11'd720

`define   h_visible_offset       11'd0
`define   h_center_offset        11'd128
`define   h_visible_offset_end   11'd1024

`define   v_visible_offset       11'd0
`define   v_visible_offset_end   11'd720
                   
                   
assign current_y = (vertical_counter >= `v_visible_offset && vertical_counter < `v_visible_offset_end) ? vertical_counter - `v_visible_offset : 11'b0;
assign current_x = (horizontal_counter >= `h_visible_offset + `h_center_offset + 11'd2 && horizontal_counter < `h_visible_offset_end + `h_center_offset - 11'd3) ? 
                                       horizontal_counter - (`h_visible_offset + `h_center_offset) : 11'b0; 
                                       
assign visible_x = (horizontal_counter >= `h_visible_offset && horizontal_counter < `h_line_timing) ? horizontal_counter - `h_visible_offset : 11'b0; 


///////////////////  MODULES  /////////////////////

teletype_charset charset_rom (
   .address(charset_address),
   .clock(clk),
   .q(character_line_data));

teletype_fb terminal_framebuf (
   .clock(clk),
   .data(reg_char_in),
   .rdaddress(fb_rdaddress),
   .wraddress(fb_wraddress),
   .wren(1'b1),
   .q(fiodec_charcode)
);
   
/******************************/


////////////////////  TASKS  //////////////////////

task receive_char;
   input [4:0] char;
begin 
   if (char == `figures)                                       /* Handle special, non-printable characters first, like */
      current_case <= 1'b1;                                    /* lowercase and uppercase. Red/Black ink to be implemented later. */

   else if (char == `letters)
      current_case <= 1'b0;                  

   else   
   begin
      if (char == `line_feed || char_x == 6'b111111)
         char_y <= char_y + 1'b1;

      else begin
         char_x <= char_x + 1'b1;                              /* Move the cursor by one place to the right and write the character to */
         reg_char_in <= {current_case, char[4:0]};             /* framebuffer, combining it with the current_case register state */    
         fb_wraddress <= { char_y, char_x };
      end
      
      if (char == `carriage_return || char_x == 6'b111111)     /* Carriage return or end of line reached, go to first column and advance one line */
         char_x <= 6'b1;
   end                                                           
end
endtask
       

////////////////  ALWAYS BLOCKS  //////////////////
       
always @(posedge clk) begin
   /* By using values from two clock cycles ago, we give it roughly enough time for the data to stabilize on input. */

   prev_prev_typewriter_strobe_in <= prev_typewriter_strobe_in;
   prev_typewriter_strobe_in <= character_strobe;
     
   edsac_strobe_in <= ~prev_prev_typewriter_strobe_in && prev_typewriter_strobe_in;
   
   /* Plain and ugly, narrow the search to two specific columns and use a lookup table, to determine if current (x, y) coord is within a circle */
   is_cursor_over_hole <= (visible_x[10:5] == 6'd3 || visible_x[10:5] == 6'd36) && is_circle_12(visible_x[4:0], vertical_counter[4:0]);                                        
               
   /* Draw a dashed line to simulate a perforated paper edges, true for two columns only and skip few rows to spread the perforations vertically */
   is_dashed_line <= (horizontal_counter == (`h_visible_offset + `h_center_offset - 1'b1) || horizontal_counter == (`h_visible_offset_end + `h_center_offset - 1'b1)) && current_y[1:0] == 0;
end              

                                       

/* horizontal and vertical pulse counters */
always @(posedge clk) begin                                
   reg [5:0] dummy_erase;
   
   /* Read from one line buffer to the screen and prepare the next line */                                   
   if (current_x[3:0] == 4'b0000)
      character_line_latch <= character_line_data;           
   
   /* Flip bit order (msb<-->lsb) and use that as the index to get the current corresponding pixel value for the character, for current x */
   pixel_out <= character_line_latch[~current_x[3:0]] ? 8'h0 : 8'hff;
      
   if ((current_y[5] ^ char_y[0]) && current_y[1] && (|current_x))     /* Paint even rows background green, to simulate perforated paper and skip every other line within even rows as well */                                                                                                        
      bg_out <= (current_y[5:0] == 6'h3f || current_y[5:0] == 6'h23) ? 8'h0 : 8'h80;      /* Paint the first and last line slightly darker */            
   else
      bg_out <= 8'hff; /* Since it's a bitmask, bitwise AND with all ones does nothing */
                                                      
   /* Do we have to erase the entire screen? While erase is active, keep overwriting the buffer with blanks */
   if (erase) begin
      fb_wraddress <= fb_wraddress + 1'b1;
      reg_char_in <= 6'd20;
   end
                           
   else if (edsac_strobe_in)
      receive_char(char_in);     
              
   /* If no character received, erase last row in a loop */
   else
   begin
      
      dummy_erase <= dummy_erase + 1'b1;
      fb_wraddress <= { char_y + 1'b1, dummy_erase };             
      reg_char_in <= 6'd20;                          
   end   
end
         

/* Given horizontal and vertical counters, indicate if we are inside the printable area margins */
always @(posedge clk) begin         
   if (horizontal_counter >= `h_visible_offset + `h_center_offset - 11'd36 && horizontal_counter < `h_visible_offset_end + `h_center_offset + 11'd36)
      inside_visible_area <= 1'b1;
   else
      inside_visible_area <= 1'b0;
         
end     


endmodule
