@echo off
REM Windows batch file to generate LST Day / LST Night for a single day as global mosaiced tif, 
REM given MODIS MOD11A2 hdf tiles as input. 
REM Pass an example filename of that day as input to specify the day, e.g.  
REM MCD43B4.A2002345.h17v00.005.2009071183311.hdf

REM This workflow has been developed to make the best use of the particular machine I ran it on in terms
REM of amount of RAM, number and speed of disks etc, to translate the MODIS files as fast as possible.
REM It may not be the best for whatever machine you are working with!
REM Specifically it makes uses of a temporary disk which should be as fast as possible - ideally a RAM drive - 
REM so that when running multiple days in parallel (see below) the disk contention is minimised. I used ImDisk to create this.

REM For a given tilename input, this file:
REM     1. Parses the date token from the filename (e.g. A2002345)
REM     2. Copies all HDFs matching that token to the temp drive
REM     3. Makes .VRTs that define a merged global image for each of LST_Day and LST_Night, 
REM         in the source sinusoidal CRS and units
REM     4. Calls calculate_temps.py to create sinusoidal GeoTIFFs representing the temperatures in the output units (Celsius)
REM     5. Calls gdalwarp to reproject these into WGS84 30 arcsecond GeoTIFFs in the output folder
REM     6. Empties the temp folder

REM Call this batch file via ppx2 utility (windows equivalent of xargs -P) to run multiple days in parallel e.g. 
REM to process a whole folder using 4 concurrent processes, use:
REM dir /B %DATA_DIR%\*.h17v07*.hdf|ppx2 -P 4 -L 1 Process_MOD11A2_Temp_From_HDF.bat "{}"

REM (On less capable machines just run all files sequentially in with a standard command for-loop)

REM This variable is necessary for working with the vrt mosaics of HDF tiles. Each process can't open more than
REM 32 HDF files at once (library limitation) which would cause GDAL to fail on translate.
set GDAL_MAX_DATASET_POOL_SIZE=30

REM Set cachemax to a value that is no more than avail mem / num processes of this batch file being run
REM bearing in mind the space on memdisk used as well, which is the HDF files for one day (c.1.5Gb / process)
REM Having it as big as possible minimises disk access i.e. it writes everything in one bunch at the end 
REM of calculations. 8Gb cache plus 1.5Gb memdisk plus 1Gb warp memory is safe and efficient for 4 processes 
REM on a 64Gb machine, 12ishGb may be slightly faster
set GDAL_CACHEMAX=8000

REM As far as possible use different drives for inputs, intermediates, temp, and outputs, for least disk contention.

REM Define drive with data on
set PROCESS_HOME=F:\HDF
REM F:\MOD11A2
set DATA_DIR=%PROCESS_HOME%\
REM mod11a2_extra
REM Define drive where output tiffs will go
set OUTPUT_HOME=G:\modis
set OUTPUTDIR=%OUTPUT_HOME%\mod11a2_v6
REM The vrts will have wrong file paths when moved (relative paths don't seem to trigger) but that's easily changed 
REM in a text editor
set VRT_DIR=%OUTPUTDIR%\VRTS

REM Set this to be a ramdisk (create with imdisk utility) with size ~2Gb per process
REM and create directories called data and vrts on it
REM This avoids disk contention where multiple processes are all trying to read their HDFs
set TEMPDISK=M:
set TMP_DATA_DIR=%TEMPDISK%\data
set TMP_VRT_DIR=%TEMPDISK%\vrts

REM get the filename that was passed in from which we will figure out what day we're working with
REM (dirty hack)
REM e.g. MOD11A2.A2014305.h35v10.005.2014315083920.hdf
set EXAMPLEDAYFILE=%1
echo %EXAMPLEDAYFILE%
for /F "tokens=2 delims=." %%d in ("%EXAMPLEDAYFILE%") do (
echo %%d
REM copy the HDFs for this day to the ramdisk. When 4 processes start at once this will cause 
REM bottleneck disk queues but as they gradually go out of sync it'll improve
REM copy %DATA_DIR%\*%%d.*.hdf %TMP_DATA_DIR%
cd %PROCESS_HOME%
for /r %%f in (*%%d.*.hdf) do copy %%f %TMP_DATA_DIR%

REM build a mosaic vrt for each band of the day
for /F "usebackq" %%t in (`dir /B %TMP_DATA_DIR%\*%%d.*.hdf`) do (
    echo HDF4_EOS:EOS_GRID:"%TMP_DATA_DIR%\%%t":MODIS_Grid_8Day_1km_LST:LST_Day_1km>> %TMP_VRT_DIR%\vrtListDay_%%d.txt
    echo HDF4_EOS:EOS_GRID:"%TMP_DATA_DIR%\%%t":MODIS_Grid_8Day_1km_LST:LST_Night_1km>> %TMP_VRT_DIR%\vrtListNight_%%d.txt
)
gdalbuildvrt -input_file_list %TMP_VRT_DIR%\vrtListDay_%%d.txt %TMP_VRT_DIR%\%%d_Day.vrt -te -20015109.356 -10007554.678 20015109.356 10007554.678 -tr 926.625433138760630 926.625433138788940
gdalbuildvrt -input_file_list %TMP_VRT_DIR%\vrtListNight_%%d.txt %TMP_VRT_DIR%\%%d_Night.vrt -te -20015109.356 -10007554.678 20015109.356 10007554.678 -tr 926.625433138760630 926.625433138788940
del %TMP_VRT_DIR%\vrtListDay_%%d.txt
del %TMP_VRT_DIR%\vrtListNight_%%d.txt

REM Calculate all output vars using python script, generating uncompressed and unprojected output tiffs 
REM on the user's temp folder, which will (hopefully!) be on C: (unless we have enough space on memdisk 
REM for these too - that would need an extra 11Gb per process!
REM Calculate on the vrt unprojected mosaics, thus minimising the number of bands we will have to warp/compress. 
REM Specify a large tile size for the temporary output tiffs as the sole priority for these is efficient access 
REM on the single time they will be written then read (by gdal warp). Larger tiles = fewer disk requests which 
REM when multiple processes are running in parallel means fewer squabbles for the disk heads.
REM This uses numexpr and sensible block sizes to calculate in avg 3 mins per day using multiple threads
python "%~dp0\calculate_temps.py" --DayInput %TMP_VRT_DIR%\%%d_Day.vrt --NightInput %TMP_VRT_DIR%\%%d_Night.vrt --DayFile %TEMP%\%%d_Day_Sinusoidal_Tmp.tif --NightFile %TEMP%\%%d_Night_Sinusoidal_Tmp.tif --type="Float32" --co="TILED=YES" --co="SPARSE_OK=TRUE" --co="BLOCKXSIZE=1024" --co="BLOCKYSIZE=1024" --NoDataValue=-9999


REM Project those indices into compressed TIFFs that are our output ready for gapfilling. Use multithreaded warping - although this only helps on the reprojection, not the writing of compressed output
REM These params give "true" global extents: 
REM     -te -180 -90 180 90 -tr 0.008333333333333 -0.008333333333333
REM but that doesn't sync with MAP's older "mastergrid" files as they have a more approximate cell size. 
REM To get these grids to line up with existing mastergrids use instead: 
REM     -te -180 -89.999988 179.9998560 89.99994 -tr 0.00833333 -0.00833333
REM alternatively translate with "true" coords as above then edit in-place with
REM     gdal_edit -a_ullr -180 89.99994 179.9998560 -89.999988 filename.tif
gdalwarp -of GTiff -co "COMPRESS=LZW" -co "PREDICTOR=2" -co "TILED=YES" -co "SPARSE_OK=TRUE" -co "NUM_THREADS=6" -multi -wo NUM_THREADS=6 -wm 1024 -t_srs "EPSG:4326" -te -180 -90 180 90 -tr 0.008333333333333 -0.008333333333333 -dstnodata -9999 %TEMP%\%%d_Day_Sinusoidal_Tmp.tif %OUTPUTDIR%\Day\%%d_LST_Day.tif
gdalwarp -of GTiff -co "COMPRESS=LZW" -co "PREDICTOR=2" -co "TILED=YES" -co "SPARSE_OK=TRUE" -co "NUM_THREADS=6" -multi -wo NUM_THREADS=6 -wm 1024 -t_srs "EPSG:4326" -te -180 -90 180 90 -tr 0.008333333333333 -0.008333333333333 -dstnodata -9999 %TEMP%\%%d_Night_Sinusoidal_Tmp.tif %OUTPUTDIR%\Night\%%d_LST_Night.tif

REM Delete the temporary uncompressed tiffs
del %TEMP%\%%d_Day_Sinusoidal_Tmp.tif
del %TEMP%\%%d_Night_Sinusoidal_Tmp.tif

REM Clear up mem disk
del %TMP_DATA_DIR%\*%%d.*.hdf
move %TMP_VRT_DIR%\*%%d*.vrt %VRT_DIR%\
)
