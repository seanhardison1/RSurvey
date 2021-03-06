#Survdat.r
#This script will generate data from the NEFSC bottom trawl surveys
#SML

#-------------------------------------------------------------------------------
#User parameters
if(Sys.info()['sysname']=="Windows"){
  data.dir <- "L:\\Rworkspace\\RSurvey"
  out.dir  <- "L:\\EcoAP\\Data\\survey"
  memory.limit(4000)
}
if(Sys.info()['sysname']=="Linux"){
  data.dir <- "/home/slucey/slucey/Rworkspace/RSurvey"
  out.dir  <- "/home/slucey/slucey/EcoAP/Data/survey"
  uid      <- 'slucey'
  cat("Oracle Password: ")
  pwd <- scan(stdin(), character(), n = 1)
}

shg.check  <- 'y' # y = use only SHG <=136 or TOGA <= 1324 (>2008)
raw.check  <- 'n' # y = save data without conversions (survdat.raw), will still 
                  #     save data with conversions (survdat)
all.season <- 'n' # y = save data with purpose code 10 not just spring/fall 
                  #     (survdat.allseason), will not save survdat regular
use.SAD    <- 'y' # y = grab data from Survey Analysis Database (SAD) for 
                  #     assessed species
#-------------------------------------------------------------------------------
#Required packages
library(RODBC); library(data.table)

#-------------------------------------------------------------------------------
#Created functions
  #Convert output to text for RODBC query
sqltext <- function(x){
  out <- x[1]
  if(length(x) > 1){
    for(i in 2:length(x)){
      out <- paste(out, x[i], sep = "','")
    }
  }
  out <- paste("'", out, "'", sep = '')
  return(out)
}

#-------------------------------------------------------------------------------
#Begin script
if(Sys.info()['sysname']=="Windows"){
  channel <- odbcDriverConnect()
} else {
  channel <- odbcConnect('sole', uid, pwd)
}

#Generate cruise list
if(all.season == 'n'){
  cruise.qry <- "select unique year, cruise6, svvessel, season
    from mstr_cruise
    where purpose_code = 10
    and year >= 1963
    and (season = 'FALL'
      or season = 'SPRING')
    order by year, cruise6"
  }

if(all.season == 'y'){
  cruise.qry <- "select unique year, cruise6, svvessel, season
    from mstr_cruise
    where purpose_code = 10
    and year >= 1963
    order by year, cruise6"
  }
    
cruise <- as.data.table(sqlQuery(channel, cruise.qry))
cruise <- na.omit(cruise)
setkey(cruise, CRUISE6, SVVESSEL)

#Use cruise codes to select other data
cruise6 <- sqltext(cruise$CRUISE6)

#Station data
if(shg.check == 'y'){
  preHB.station.qry <- paste("select unique cruise6, svvessel, station, stratum,
                             tow, decdeg_beglat as lat, decdeg_beglon as lon, 
                             begin_est_towdate as est_towdate, avgdepth as depth, 
                             surftemp, surfsalin, bottemp, botsalin
                             from Union_fscs_svsta
                             where cruise6 in (", cruise6, ")
                             and SHG <= 136
                             and cruise6 <= 200900
                             order by cruise6, station", sep='')
  
  HB.station.qry <- paste("select unique cruise6, svvessel, station, stratum,
                          tow, decdeg_beglat as lat, decdeg_beglon as lon, 
                          begin_est_towdate as est_towdate, avgdepth as depth, 
                          surftemp, surfsalin, bottemp, botsalin
                          from Union_fscs_svsta
                          where cruise6 in (", cruise6, ")
                          and TOGA <= 1324
                          and cruise6 > 200900
                          order by cruise6, station", sep='')
  
  preHB.sta <- as.data.table(sqlQuery(channel, preHB.station.qry))
  HB.sta    <- as.data.table(sqlQuery(channel, HB.station.qry))
  station   <- rbindlist(list(preHB.sta, HB.sta))
  }

if(shg.check == 'n'){
  station.qry <- paste("select unique cruise6, svvessel, station, stratum, tow,
                       decdeg_beglat as lat, decdeg_beglon as lon, 
                       begin_est_towdate as est_towdate, avgdepth as depth, 
                       surftemp, surfsalin, bottemp, botsalin
                       from UNION_FSCS_SVSTA
                       where cruise6 in (", cruise6, ")
                       order by cruise6, station", sep='')
  station <- as.data.table(sqlQuery(channel, station.qry))
  }
  
setkey(station, CRUISE6, SVVESSEL)

#merge cruise and station
survdat <- merge(cruise, station)


#Catch data
catch.qry <- paste("select cruise6, station, stratum, tow, svspp, catchsex, 
                   expcatchnum as abundance, expcatchwt as biomass
                   from UNION_FSCS_SVCAT
                   where cruise6 in (", cruise6, ")
                   and stratum not like 'YT%'
                   order by cruise6, station, svspp", sep='')

catch <- as.data.table(sqlQuery(channel, catch.qry))
setkey(catch, CRUISE6, STATION, STRATUM, TOW)

#merge with survdat
setkey(survdat, CRUISE6, STATION, STRATUM, TOW)
survdat <- merge(survdat, catch, by = key(survdat))

#Length data
length.qry <- paste("select cruise6, station, stratum, tow, svspp, catchsex, 
                    length, expnumlen as numlen
                    from UNION_FSCS_SVLEN
                    where cruise6 in (", cruise6, ")
                    and stratum not like 'YT%'
                    order by cruise6, station, svspp, length", sep='')

len <- as.data.table(sqlQuery(channel, length.qry))
setkey(len, CRUISE6, STATION, STRATUM, TOW, SVSPP, CATCHSEX)

#merge with survdat
setkey(survdat, CRUISE6, STATION, STRATUM, TOW, SVSPP, CATCHSEX)
survdat <- merge(survdat, len, all.x = T)

if(raw.check == 'y'){
  survdat.raw <- survdat
  save(survdat.raw, file = paste(out.dir, "Survdat_raw.RData", sep =''))
  }

#Conversion Factors
#need to make abundance column a double instead of an integer
survdat[, ABUNDANCE := as.double(ABUNDANCE)]

#Grab all conversion factors off the network
convert.qry <- "select *
  from survan_conversion_factors"

convert <- as.data.table(sqlQuery(channel,convert.qry))

#DCF < 1985 Door Conversion
dcf.spp <- convert[DCF_WT > 0, SVSPP]
for(i in 1:length(dcf.spp)){
  survdat[YEAR < 1985 & SVSPP == dcf.spp[i],
      BIOMASS := BIOMASS * convert[SVSPP == dcf.spp[i], DCF_WT]]
  }
dcf.spp <- convert[DCF_NUM > 0, SVSPP]
for(i in 1:length(dcf.spp)){
  survdat[YEAR < 1985 & SVSPP == dcf.spp[i],
      ABUNDANCE := round(ABUNDANCE * convert[SVSPP == dcf.spp[i], DCF_NUM])]
  }

#GCF Spring 1973-1981  Net Conversion
gcf.spp <- convert[GCF_WT > 0, SVSPP]
for(i in 1:length(gcf.spp)){
  survdat[SEASON == 'SPRING' & YEAR > 1972 & YEAR < 1982 & SVSPP == gcf.spp[i],
      BIOMASS := BIOMASS / convert[SVSPP == gcf.spp[i], GCF_WT]]
  }
gcf.spp <- convert[GCF_NUM > 0, SVSPP]
for(i in 1:length(gcf.spp)){
  survdat[SEASON == 'SPRING' & YEAR > 1972 & YEAR < 1982 & SVSPP == gcf.spp[i],
      ABUNDANCE := round(ABUNDANCE / convert[SVSPP == gcf.spp[i], GCF_NUM])]
  }

#VCF SVVESSEL = DE  Vessel Conversion
vcf.spp <- convert[VCF_WT > 0, SVSPP]
for(i in 1:length(vcf.spp)){
  survdat[SVVESSEL == 'DE' & SVSPP == vcf.spp[i],
      BIOMASS := BIOMASS * convert[SVSPP == vcf.spp[i], VCF_WT]]
  }
vcf.spp <- convert[VCF_NUM > 0, SVSPP]
for(i in 1:length(vcf.spp)){
  survdat[SVVESSEL == 'DE' & SVSPP == vcf.spp[i],
      ABUNDANCE := round(ABUNDANCE * convert[SVSPP == vcf.spp[i], VCF_NUM])]
  }

#Bigelow >2008 Vessel Conversion - need flat files (not on network)
#Use Bigelow conversions for Pisces as well (PC)
big.fall   <- as.data.table(read.csv(file.path(data.dir, 
                                               'bigelow_fall_calibration.csv')))
big.spring <- as.data.table(read.csv(file.path(data.dir, 
                                               'bigelow_spring_calibration.csv')))

bf.spp <- big.fall[pW != 1, svspp]
for(i in 1:length(bf.spp)){
  survdat[SVVESSEL %in% c('HB', 'PC') & SEASON == 'FALL' & SVSPP == bf.spp[i],
      BIOMASS := BIOMASS / big.fall[svspp == bf.spp[i], pW]]
  }
bf.spp <- big.fall[pw != 1, svspp]
for(i in 1:length(bf.spp)){
  survdat[SVVESSEL %in% c('HB', 'PC') & SEASON == 'FALL' & SVSPP == bf.spp[i],
      ABUNDANCE := round(ABUNDANCE / big.fall[svspp == bf.spp[i], pw])]
  }

bs.spp <- big.spring[pW != 1, svspp]
for(i in 1:length(bs.spp)){
  survdat[SVVESSEL %in% c('HB', 'PC') & SEASON == 'SPRING' & SVSPP == bs.spp[i],
      BIOMASS := BIOMASS / big.spring[svspp == bs.spp[i], pW]]
  }
bs.spp <- big.spring[pw != 1, svspp]
for(i in 1:length(bs.spp)){
  survdat[SVVESSEL %in% c('HB', 'PC') & SEASON == 'SPRING' & SVSPP == bs.spp[i],
      ABUNDANCE := round(ABUNDANCE / big.spring[svspp == bs.spp[i], pw])]
  }

if(use.SAD == 'y'){
  sad.qry <- "select svspp, cruise6, stratum, tow, station, sex as catchsex,
             catch_wt_B_cal, catch_no_B_cal, length, length_no_B_cal
             from STOCKEFF.I_SV_MERGED_CATCH_CALIB_O"
  sad     <- as.data.table(sqlQuery(channel, sad.qry))
  
  setkey(sad, CRUISE6, STRATUM, TOW, STATION, SVSPP, CATCHSEX, LENGTH)
  sad <- unique(sad)
  survdat <- merge(survdat, sad, by = key(sad), all.x = T)
  
  #Carry over SAD values to survdat columns and delete SAD columns
  survdat[!is.na(CATCH_WT_B_CAL),  BIOMASS   := CATCH_WT_B_CAL]
  survdat[!is.na(CATCH_NO_B_CAL),  ABUNDANCE := CATCH_NO_B_CAL]
  survdat[, NUMLEN := as.double(NUMLEN)]
  survdat[!is.na(LENGTH_NO_B_CAL), NUMLEN    := LENGTH_NO_B_CAL]
  survdat[, c('CATCH_WT_B_CAL', 'CATCH_NO_B_CAL', 'LENGTH_NO_B_CAL') := NULL]
}

odbcClose(channel)

if(all.season == 'n') save(survdat, file = file.path(out.dir, "Survdat.RData"))
if(all.season == 'y') save(survdat, file = file.path(out.dir, 
                                                     "Survdat_allseason.RData"))




