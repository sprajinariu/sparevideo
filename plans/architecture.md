## Input
- VGA 320 x 240 (QVGA) 60Hz camera input 
  Video formats could be:
    RGB444 - 4 bits for each color.
    RGB565 - 5bit red, 6 bit green, 5bit blue. 
- Start with something simpler.


## Output
- VGA 320x240 or 640x480
- DP DisplayPort
- ethernet MAC

## clocks
- pixel_clk_in for input camera -- 25MHz
- proc_clk -- 200 MHz.
- pixel_clk_out for output video -- 

## Architecture considerations
- processing is done on a faster clock, typically 2-4x compared to pixel clock.
- once display starts, it must never pause otherwise there will be screen tearing.
- Options to traverse between proc_clk and pixel_clk_out:

    OPTION 1: small async FIFO + backpressure into proc_clk domain.
        Use-case: fully streaming pipeline, full frames are not stored.
        proc_clk is slower, it will read at exaclty the pixel rate.
        Pre-fill FIFO (to a start-threshold of 1-4 lines) before starting output display .
    
    OPTION 2: double buffering. Store frames in RAM, use 2 frame buffers.
        Use-case: Full frames are required for intensive processing.
        processing writes full frames in buffer A.
        output reads previous frame from buffer B.
        when done -> swap buffers.
        Pipeline adds 1 frame latency to video stream.
        Buffer A and Buffer B can be simply implemented as different single-port RAMs: clock selection is done per frame,
        depending if it's the processed buffer or read buffer.
        
    OPTION 3: line-based buffering. Use line-buffers in dual-port RAM.
        Needs true dual-port RAM.
     
FIRST: use OPTION 2 with RAMs, it is simpler, it avoids ugly dependencies, and is flexible for processing.
    Maybe switch to line-buffers and async FIFOs later.


## Internal blocks
mipi_csi2_rx:
    - camera input
    - translate video stream into axi4s protocol
    - standard: https://docs.amd.com/r/5.3-English/pg232-mipi-csi2-rx/MIPI-CSI-2-Receiver-Subsystem-Product-Guide

FPN + PRNU:
    -   first removes sensor noise (fixed pattern noise (FPN))
    -   performs an equalization of the individual pixel responses (pixel response non-uniformity (PRNU))
    -   Uses reference black and white images stored in RAM (computed and applied by python over the input video frames)
    -   Reference black and white images are pre-loaded before simulation, emulating a "calibration" step.
    Fixed pattern noise is inherent to CMOS/CCD sensors and describes the accumulated charges in the pixel sensors
    that are not due to incoming photons. This noise can be characterized by measuring a black image with no light incidence, for a given exposure period. 
    This reference image can then simply be subtracted in the following camera operation. 
    The individual CMOS pixels usually exhibit different response characteristics. This response characteristic can
    be measured by imaging a homogeneously lit white surface (white image). Then, during camera operation, the
    incoming images can be normalized to the measured intensities from the white level measurement, after FPN
    correction has been applied. This measurement implicitly includes the white balance.
    The black and white reference images are of the same size as the incoming video frames. 
    These reference images are stored in RAM.
    
Bayer demosaicing: 
    -   Conversion to full color by color interpolation (Bayer demosaicing)
    -   probably needs a 5 line buffer
    Most CMOS sensors apply a color filter similar to the Bayer pattern to capture color images with a single sensor only. 
    In order to reconstruct a full-resolution color image, interpolation filters have to be applied. In this architecture, 
    a linear filter based on the Wiener filter with window size of 5 × 5 pixels is used [16].
    
    The FPGA implementation stores 5 lines for each video in a temporary line cache to perform the interpolation.
    The arithmetics of the interpolation [16] can be efficiently implemented using adders and bit shifts only.
    [16]: Malvar H, He LW, Cutler R: High-quality linear interpolation for
    demosaicing of Bayer-patterned color images. Proceedings of the IEEE
    International Conference on Acoustics, Speech, and Signal Processing 2004,
    3:485-488.

Operations should be performed accurately in fixed-point arithmetic.

vga_gen - generate video timing for output
    hcount, vcount
    hsync,  vsync

Scaler: 
    - mirror: EN=1 mirrors the video input for use-cases like selfie camera.
        This is done by inverting pixel i with 320-i for each line.
    - scales from 320x240 to 1:1 or 2:1 (640x480).

Dithering:
    - temporal (between same pixels of different frames)
    - spatial  (between pixels of the same frames)

Color correction:
    Color corrections are done individually per pixel, after all blending and/or image resampling operations. The intended purpose is to:
    - compensate for display specific characteristics (e.g. gamma, white point, sRGB)
    - apply user-controlled parameters (e.g. brightness, contrast, saturation)
    The GammaCor operation is a programmable look-up table for each color channel.
    The tables do not have an entry for each of the 1024 possible input codes (0, 1, 2, ..., 
    1023), but only for codes dividable by 32 (0, 32, 64, ..., 1024). Codes in-between are 
    computed as a linear interpolation from the two nearest neighbors.


BRAM:
- single buffer: same buffer written and read.
- tripple buffer: Write, Read and Ready

? rgb_to_ycrcb:
    -   transfom from RGB to YCrCb color space, for output display?
    -   could be needed for processing, center mass crosshair
   


## Structure

  Camera  -> FIFO_IN  -> MIRROR -> RAM -> SCALER -> FIFO_OUT -> VGA_GEN
          

## Considerations
- during processing, take care that different processing paths may implement different pipeline stages
  That means that latency will be different for those different blocks.
  Make sure that latency is compensated by adding pipeline stages for hcount/vcount.
