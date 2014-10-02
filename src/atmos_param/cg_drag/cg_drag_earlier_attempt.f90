                 module cg_drag_mod

use fms_mod,                only:  fms_init, mpp_pe, mpp_root_pe,  &
                                   file_exist, check_nml_error,  &
                                   error_mesg,  FATAL, WARNING, NOTE, &
                                   close_file, open_namelist_file, &
                                   stdlog, write_version_number, &
                                   read_data, write_data,   &
                                   open_restart_file
use time_manager_mod,       only:  time_manager_init, time_type
use diag_manager_mod,       only:  diag_manager_init,   &
                                   register_diag_field, send_data
use constants_mod,          only:  constants_init, PI, RDGAS, GRAV, CP_AIR

!epg - I have attempted to remove the presence of anything from 
!      column_diagnostics_mod


implicit none
private

!---------------------------------------------------------------------
!    cg_drag_mod computes the convective gravity wave forcing on 
!    the zonal flow. the parameterization is described in Alexander and 
!    Dunkerton [JAS, 15 December 1999]. 
!--------------------------------------------------------------------
  

!---------------------------------------------------------------------
!----------- ****** VERSION NUMBER ******* ---------------------------


character(len=128)  :: version =  '$Id: cg_drag.f90,v 13.0 2006/03/28 21:07:22 fms Exp $'
character(len=128)  :: tagname =  '$Name: memphis $'



!---------------------------------------------------------------------
!-------  interfaces --------

public    cg_drag_init, cg_drag_calc, cg_drag_end


private   read_restart_file, gwfc


!wfc++ Addition for regular use
      integer, allocatable, dimension(:,:)     ::  source_level

      real,     allocatable, dimension(:,:)     ::  source_amp
!wfc--


!--------------------------------------------------------------------
!---- namelist -----

integer     :: cg_drag_freq=0     ! calculation frequency [ s ]
integer     :: cg_drag_offset=0   ! offset of calculation from 00Z [ s ]
                                  ! only has use if restarts are written
                                  ! at 00Z and calculations are not done
                                  ! every time step

real        :: source_level_pressure= 315.e+02    
                                  ! highest model level with  pressure 
                                  ! greater than this value (or sigma
                                  ! greater than this value normalized
                                  ! by 1013.25 hPa) will be the gravity
                                  ! wave source level at the equator 
                                  ! [ Pa ]
integer     :: nk=1               ! number of wavelengths contained in 
                                  ! the gravity wave spectrum
real        :: cmax=99.6          ! maximum phase speed in gravity wave
                                  ! spectrum [ m/s ]
real        :: dc=1.2             ! gravity wave spectral resolution 
                                  ! [ m/s ]
                                  ! previous values: 0.6
real        :: Bt_0=.003          ! sum across the wave spectrum of 
                                  ! the magnitude of momentum flux, 
                                  ! divided by density [ m^2/s^2 ]
            
real        :: Bt_aug=.000        ! magnitude of momentum flux divided by density 

real        :: Bt_nh=.003         ! magnitude of momentum flux divided by density   (SH limit )

real        :: Bt_sh=.003         ! magnitude of momentum flux divided by density  (SH limit )

real        :: Bt_eq=.000         ! magnitude of momentum flux divided by density  (equator) 

real        :: Bt_eq_width=4.0    ! scaling for width of equtorial momentum flux  (equator) 

real        :: phi0n = 30., phi0s = -30., dphin = 5., dphis = -5.

! epg: calculate_ked is gone, so clean this up
! epg: also clean up column diagnostics stuff

integer, parameter           ::  MAX_PTS= 20
                                  ! maximum number of diagnostic columns
integer, dimension(MAX_PTS)  ::  i_coords_gl=-100     
                                  ! global i coordinates for ij 
                                  ! diagnostic columns 
integer, dimension(MAX_PTS)  ::  j_coords_gl=-100   
                                  ! global j coordinates for ij 
                                  ! diagnostic columns 
real,    dimension(MAX_PTS)  ::  lat_coords_gl=-999. 
                                  ! latitudes for latlon diagnostic 
                                  ! columns  [degrees, -90. -> 90. ]
real,    dimension(MAX_PTS)  ::  lon_coords_gl=-999. 
                                  ! longitudes for latlon diagnostic 
                                  ! columns [ degrees, 0. -> 360. ]

!epg: a flag to turn off the drag
logical  :: no_cg_drag = .false.

namelist / cg_drag_nml /         &
                          cg_drag_freq, cg_drag_offset, &
                          source_level_pressure,   &
                          nk, cmax, dc, Bt_0, Bt_aug,  &
                          Bt_sh, Bt_nh, Bt_eq,  Bt_eq_width,  &
                          phi0n,phi0s,dphin,dphis, &                    
                          i_coords_gl, j_coords_gl,   &
                          lat_coords_gl, lon_coords_gl, &
                          no_cg_drag

!--------------------------------------------------------------------
!-------- public data  -----


!--------------------------------------------------------------------
!------ private data ------

!--------------------------------------------------------------------
!   list of restart versions readable by this module.
!--------------------------------------------------------------------
integer, dimension(2)  :: restart_versions = (/ 1, 2 /)

!--------------------------------------------------------------------
!   these arrays must be preserved across timesteps in case the
!   parameterization is not called every timestep:
!
!   gwd      time tendency for u eqn due to gravity wave forcing 
!            [ m/s^2 ]
!   ked      effective eddy diffusion coefficient resulting from 
!            gravity wave forcing [ m^2/s ]
!
!--------------------------------------------------------------------
!wfc++ not needed if calcucate_ked is removed.
!!!!rjw real,    dimension(:,:,:), allocatable   :: gwd, ked
!wfc--
!--------------------------------------------------------------------
!   these are the arrays which define the gravity wave source spectrum:
!
!   c0       gravity wave phase speeds [ m/s ]
!   kwv      horizontal wavenumbers of gravity waves  [  /m ]
!   k2       squares of wavenumbers [ /(m^2) ]
!
!-------------------------------------------------------------------
real,    dimension(:),     allocatable   :: c0, kwv, k2


!---------------------------------------------------------------------
!   wave spectrum parameters.
!---------------------------------------------------------------------
integer    :: nc        ! number of wave speeds in spectrum
                        ! (symmetric around c = 0)
integer    :: flag = 1  ! flag = 1  for peak flux at  c    = 0
                        ! flag = 0  for peak flux at (c-u) = 0
real       :: Bw = 0.4  ! amplitude for the wide spectrum [ m^2/s^2 ]  
                        ! ~ u'w'
real       :: Bn = 0.0  ! amplitude for the narrow spectrum [ m^2/s^2 ] 
                        ! ~ u'w';  previous values: 5.4
real       :: cw = 40.0 ! half-width for the wide c spectrum [ m/s ]
                        ! previous values: 50.0, 25.0 
real       :: cn =  2.0 ! half-width for the narrow c spectrum  [ m/s ]
integer    :: klevel_of_source
                        ! k index of the gravity wave source level at
                        ! the equator in a standard atmosphere

!---------------------------------------------------------------------
!   variables which control module calculations:
!   
!   pts_processed
!                counter of current number of columns which have been
!                processed on this step
!   total_pts    number of columns which must be processed on each step
!   cgdrag_alarm time remaining until next cg_drag calculation  [ s ]
!
!---------------------------------------------------------------------
integer          :: pts_processed, total_pts, cgdrag_alarm


! epg: I killed all of the column diagnostics stuff
!---------------------------------------------------------------------
!   variables used with column diagnostics:
!
!   diag_units     output unit numbers
!   num_diag_pts   number of columns where diagnostics are desired 
!   column_diagnostics_desired
!                  column diagnostics are desired ?
!   do_column_diagnostics 
!                  a diagnostic column is in this jrow ?  
!   diag_lon       longitude of diagnostic columns [ degrees ]
!   diag_lat       latiude of diagnostic columns  [ degrees ]
!   diag_i         processor-based i index of diagnostic columns
!   diag_j         processor-based j index of diagnostic columns
!
!--------------------------------------------------------------------

!---------------------------------------------------------------------
!   variables for netcdf diagnostic fields.
!---------------------------------------------------------------------
!rjw integer          :: id_ked_cgwd, id_bf_cgwd, id_gwf_cgwd
integer          :: id_kedx_cgwd, id_kedy_cgwd, id_bf_cgwd, &
                    id_gwfx_cgwd, id_gwfy_cgwd
real             :: missing_value = -999.
character(len=7) :: mod_name = 'cg_drag'


logical          :: module_is_initialized=.false.

!-------------------------------------------------------------------
!-------------------------------------------------------------------



                        contains

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
!                      PUBLIC SUBROUTINES
!
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


!####################################################################

!epg: I'm trying to replace lonb, latb, and pref, with variables that
!     are more readily available in atmosphere.f90
!subroutine cg_drag_init (lonb, latb, pref, Time, axes)
subroutine cg_drag_init (number_lon, rad_lat, pref, Time, axes)

!-------------------------------------------------------------------
!   cg_drag_init is the constructor for cg_drag_mod.
!-------------------------------------------------------------------

!-------------------------------------------------------------------
!real,    dimension(:), intent(in)      :: lonb, latb, pref
integer, intent(in)                    :: number_lon
real,    dimension(:), intent(in)      :: rad_lat, pref

integer, dimension(4), intent(in)      :: axes
type(time_type),       intent(in)      :: Time
!-------------------------------------------------------------------

!-------------------------------------------------------------------
!   intent(in) variables:
!
!       !lonb      array of model longitudes on cell boundaries [radians]
!       !latb      array of model latitudes at cell boundaries [radians]
!   epg: modified the program  
!       number_lon number of longitudinal grid points       
!       rad_lat    array of model latitudes at the grid point centers
!                  (radians)  
! 
!       pref      array of reference pressures at full levels 
!                 epg: WITHOUT the surface value at nlev+1, 
!                 based on 1013.25hPa pstar
!                 [ Pa ]
!   epg: I don't understand what is mean by "pstar"  My bottom level
!       is defined by P00 in hs_forcing.f90 - generally 1e5 Pa
!    
!       Time      current time (time_type)
!       axes      data axes for diagnostics
!
!------------------------------------------------------------------

!-------------------------------------------------------------------
!   local variables: 

      integer                 :: unit, ierr, io
      integer                 :: n, i, j, k
      integer                 :: idf, jdf, kmax
      real                    :: pif = 3.14159265358979/180.

!wfc ++ added for definition of source_level, source_amp.
      real, allocatable       ::   lat(:,:)
!wfc--
!-------------------------------------------------------------------
!   local variables: 
!   
!       unit           unit number for nml file 
!       ierr           error return flag 
!       io             error return code 
!       n              loop index
!       k              loop index
!       idf            number of i points on this processor
!       jdf            number of j points on this processor
!       kmax           number of k points on this processor
!
!---------------------------------------------------------------------

!---------------------------------------------------------------------
!    if routine has already been executed, return.
!---------------------------------------------------------------------
      if (module_is_initialized) return

!---------------------------------------------------------------------
!    verify that all modules used by this module have been initialized.
!---------------------------------------------------------------------
      call fms_init
      call time_manager_init
      call diag_manager_init
      call constants_init

!wfc--
!---------------------------------------------------------------------
!    read namelist.
!---------------------------------------------------------------------
      if (file_exist('input.nml')) then
        unit =  open_namelist_file ( )
        ierr=1; do while (ierr /= 0)
        read (unit, nml=cg_drag_nml, iostat=io, end=10)
        ierr = check_nml_error (io, 'cg_drag_nml')
        enddo
10      call close_file (unit)
      endif

!---------------------------------------------------------------------
!    write version number and namelist to logfile.
!---------------------------------------------------------------------
      call write_version_number (version, tagname)
      if (mpp_pe() == mpp_root_pe()) write (stdlog(), nml=cg_drag_nml)

!-------------------------------------------------------------------
!  define the grid dimensions. idf and jdf are the (i,j) dimensions of 
!  domain on this processor, kmax is the number of model layers.
!-------------------------------------------------------------------
 
      ! epg: modified this to work with hs_forcing.f90
      !kmax = size(pref(:)) - 1 
      !jdf  = size(latb(:)) - 1
      !idf  = size(lonb(:)) - 1
      kmax = size(pref(:))
      jdf = size(rad_lat)
      idf = number_lon

!wfc++ new code
      allocate(  source_level(idf,jdf)  )
      allocate(  source_amp(idf,jdf)  )

      allocate(  lat(idf,jdf)  )
!wfc--

!--------------------------------------------------------------------
!    define the k level which will serve as source level for the grav-
!    ity waves. it is that model level just below the pressure specif-
!    ied as the source location via namelist input.
!--------------------------------------------------------------------
      do k=1,kmax
        if (pref(k) > source_level_pressure) then
          klevel_of_source = k
          exit
        endif
      end do

     

!wfc++ new code
        do j=1,jdf
          !epg:replaced this with my new rad_lat
          !lat(:,j)=  0.5*( latb(j+1)+latb(j) )
          lat(:,j) = rad_lat(j)
          do i=1,idf
            source_level(i,j) = (kmax + 1) - ((kmax + 1 -    &
                                klevel_of_source)*cos(lat(i,j)) + 0.5)

!rjw             source_amp(i,j)= Bt_0 +                         &
!rjw                             Bt_eq*exp( -Bt_eq_width*lat(i,j)*lat(i,j) )  + &
!rjw                             (Bt_nh-Bt_sh)*(1.0+tanh(4.0*lat(i,j)))/2.0 + Bt_sh

            source_amp(i,j) = Bt_0 +                         &
                        Bt_nh*0.5*(1.+tanh((lat(i,j)/pif-phi0n)/dphin)) + &
                        Bt_sh*0.5*(1.+tanh((lat(i,j)/pif-phi0s)/dphis))
          end do
        end do
        source_level = MIN (source_level, kmax-1)

       deallocate( lat )
!wfc--


! epg: kill this column diagnostics stuff
!---------------------------------------------------------------------
!    determine if column diagnostics are desired from this module. if
!    so, set a flag to so indicate.
!---------------------------------------------------------------------


!---------------------------------------------------------------------
!    define the number of waves in the gravity wave spectrum, and define
!    an array of their speeds. They are defined symmetrically around
!    c = 0.0 m/s.
!---------------------------------------------------------------------
      nc = 2.0*cmax/dc + 1
      allocate ( c0(nc) )
      do n=1,nc
        c0(n) = (n-1)*dc - cmax
      end do
 
!--------------------------------------------------------------------
!    define the wavenumber kwv and its square k2 for the gravity waves 
!    contained in the spectrum. currently nk = 1, which means that the 
!    wavelength of all gravity waves considered is 300 km. 
!--------------------------------------------------------------------
      allocate ( kwv(nk) )
      allocate ( k2 (nk) )
      do n=1,nk
        kwv(n) = 2.*PI/((30.*(10.**n))*1.e3)
        k2(n) = kwv(n)*kwv(n)
      end do

!--------------------------------------------------------------------
!    initialize netcdf diagnostic fields.
!-------------------------------------------------------------------
      id_bf_cgwd =  &
         register_diag_field (mod_name, 'bf_cgwd', axes(1:3), Time, &
              'buoyancy frequency from cg_drag', ' /s',   &
              missing_value=missing_value)
!rjw      id_gwf_cgwd =  &
!rjw         register_diag_field (mod_name, 'gwf_cgwd', axes(1:3), Time, &
!rjw              'gravity wave forcing on mean flow', &
!rjw              'm/s^2',  missing_value=missing_value)

      id_gwfx_cgwd =  &
         register_diag_field (mod_name, 'gwfx_cgwd', axes(1:3), Time, &
              'gravity wave forcing on mean flow', &
              'm/s^2',  missing_value=missing_value)
      id_gwfy_cgwd =  &
         register_diag_field (mod_name, 'gwfy_cgwd', axes(1:3), Time, &
              'gravity wave forcing on mean flow', &
              'm/s^2',  missing_value=missing_value)
!wfc++ remove
!!!      if (calculate_ked) then
!wfc--
!rjw        id_ked_cgwd =  &
!rjw         register_diag_field (mod_name, 'ked_cgwd', axes(1:3), Time, &
!rjw               'effective eddy viscosity from cg_drag', 'm^2/s',   &
!rjw               missing_value=missing_value)
        id_kedx_cgwd =  &
         register_diag_field (mod_name, 'kedx_cgwd', axes(1:3), Time, &
               'effective eddy viscosity from cg_drag', 'm^2/s',   &
               missing_value=missing_value)
        id_kedy_cgwd =  &
         register_diag_field (mod_name, 'kedy_cgwd', axes(1:3), Time, &
               'effective eddy viscosity from cg_drag', 'm^2/s',   &
               missing_value=missing_value)
!wfc++ remove
!!!      endif
!wfc--
!---------------------------------------------------------------------
!    initialize counters needed when cg_drag is not calculated on every
!    time step. 
!---------------------------------------------------------------------
      total_pts = idf*jdf
      pts_processed = 0

!--------------------------------------------------------------------
!    allocate and define module variables to hold values across 
!    timesteps, in the event that cg_drag is not called on every step.
!--------------------------------------------------------------------


!---------------------------------------------------------------------
!    mark the module as initialized.
!---------------------------------------------------------------------
      module_is_initialized = .true.

!---------------------------------------------------------------------



end subroutine cg_drag_init



!####################################################################

!wfc++ need to add iloc, jloc?
!rjw  subroutine cg_drag_calc (is, js, lat, pfull, zfull,    &
!rjw                          temp, uuu, Time, delt, gwfcng)
! epg: I'm going to try and eliminate the need for delt, which is only used
!      for setting cg_drag_alarm, which doesn't appear to be used anymore
!subroutine cg_drag_calc (is, js, lat, pfull, zfull, temp, uuu, vvv,  &
!                         Time, delt, gwfcng_x, gwfcng_y)
subroutine cg_drag_calc (is, js, lat, pfull, zfull, temp, uuu, vvv,  &
                         Time, gwfcng_x, gwfcng_y)

!wfc--
!--------------------------------------------------------------------  
!    cg_drag_calc defines the arrays needed to calculate the convective
!    gravity wave forcing, calls gwfc to calculate the forcing, returns 
!    the desired output fields, and saves the values for later retrieval
!    if they are not calculated on every timestep.
!
!---------------------------------------------------------------------

!---------------------------------------------------------------------
integer,                intent(in)      :: is, js
!wfc++ new arguments not in interface
!rjw integer,                intent(in)      :: iloc, jloc
!wfc--
real, dimension(:,:),   intent(in)      :: lat
real, dimension(:,:,:), intent(in)      :: pfull, zfull, temp, uuu, vvv
type(time_type),        intent(in)      :: Time
! epg: I removed delt from the code
!real           ,        intent(in)      :: delt
!rjw real, dimension(:,:,:), intent(out)     :: gwfcng
real, dimension(:,:,:), intent(out)     :: gwfcng_x, gwfcng_y

!-------------------------------------------------------------------
!    intent(in) variables:
!
!       is,js    starting subdomain i,j indices of data in 
!                the physics_window being integrated
!       lat      array of model latitudes at cell boundaries [radians]
!       pfull    pressure at model full levels [ Pa ]
!       zfull    height at model full levels [ m ]
!       temp     temperature at model levels [ deg K ]
!       uuu      zonal wind  [ m/s ]
!       Time     current time, needed for diagnostics [ time_type ]
!       delt     physics time step [ s ]
!
!    intent(out) variables:
!
!       gwfcng   time tendency for u eqn due to gravity-wave forcing
!                [ m/s^2 ]
!
!-------------------------------------------------------------------

!-------------------------------------------------------------------
!    local variables:

      real,    dimension (size(uuu,1), size(uuu,2), size(uuu,3))  ::  &
                                         dtdz, ked_gwfc_x, ked_gwfc_y

      real,    dimension (size(uuu,1),size(uuu,2), 0:size(uuu,3)) ::  &
                                         zzchm, zu, zv, zden, zbf,    &
                                         gwd_xtnd, ked_xtnd, &
                                         gwd_ytnd, ked_ytnd


      integer           :: iz0
      logical           :: used
      real              :: bflim = 2.5E-5
      integer           :: ie, je
      integer           :: imax, jmax, kmax
      integer           :: i, j, k, nn
      real              :: pif = 3.14159265358979/180.

!-------------------------------------------------------------------
!    local variables:
!
!       dtdz          temperature lapse rate [ deg K/m ]
!       ked_gwfc      effective diffusion coefficient from cg_drag_mod 
!                     [ m^2/s ]
!       zzchm         heights at model levels [ m ]
!       zu            zonal velocity [ m/s ]
!       zden          atmospheric density [ kg/m^3 ]
!       zbf           buoyancy frequency [ /s ]
!       gwd_xtnd      zonal wind tendency resulting from cg_drag_mod 
!                     [ m/s^2 ]
!       ked_xtnd      effective diffusion coefficient from cg_drag_mod 
!                     [ m^2/s ]
!       source_level  k index of gravity wave source level ((i,j) array)
!       iz0           k index of gravity wave source level in a column
!       used          return code for netcdf diagnostics
!       bflim         minimum allowable value of squared buoyancy 
!                     frequency [ /s^2 ]
!       ie, je        ending subdomain indices of data in the current 
!                     physics window being integrated
!       imax, jmax, kmax 
!                     physics window dimensions
!       i, j, k, nn   do loop indices
!
!---------------------------------------------------------------------


      if (no_cg_drag) return


!---------------------------------------------------------------------
!    define processor extents and loop limits.
!---------------------------------------------------------------------
      imax = size(uuu,1)
      jmax = size(uuu,2)
      kmax = size(uuu,3)
      ie = is + imax - 1
      je = js + jmax - 1

!---------------------------------------------------------------------
!    if this is the first entry into this module on this timestep,
!    decrement the time remaining until the next cg_drag calculation.
!---------------------------------------------------------------------
 
! epg: to the best of my knowledge, the cgdrag_alarm is not being used
!      thus I don't need the delt variable, I think.
!     if (pts_processed == 0) then
!        cgdrag_alarm = cgdrag_alarm - delt
!      endif

!---------------------------------------------------------------------
!    if the convective gravity wave forcing should be calculated on 
!    this timestep (i.e., the alarm has gone off), proceed with the
!    calculation.
!---------------------------------------------------------------------


!wfc++ no alarm anymore?
!!!rjw      if (cgdrag_alarm <= 0) then
!wfc--

!----------------------------------------------------------------------
!    define the source level for gravity waves for each model column. 
!    it will be highest at equator and lowest near the poles. prevent 
!    it from being the lowest model level (which will occur only very 
!    near the poles with the current formulation.)
!----------------------------------------------------------------------
!wfc++ removed as these are constant.

!!wfc-- 
!-----------------------------------------------------------------------
!    calculate temperature lapse rate. do one-sided differences over 
!    delta z at upper boundary and centered differences over 2 delta z 
!    in the interior.  dtdz is not needed at the lower boundary, since
!    the source level is constrained to be above level kmax.
!----------------------------------------------------------------------
        do j=1,jmax
          do i=1,imax
            iz0 = source_level(i,j)
            dtdz(i,j,1) = (temp  (i,j,1) - temp  (i,j,2))/    &
                          (zfull(i,j,1) - zfull(i,j,2))
            do k=2,iz0
              dtdz(i,j,k) = (temp  (i,j,k-1) - temp  (i,j,k+1))/   &
                            (zfull(i,j,k-1) - zfull(i,j,k+1))
            end do

!--------------------------------------------------------------------
!    calculate air density.
!--------------------------------------------------------------------
            do k=1,iz0+1
              zden(i,j,k  ) = pfull(i,j,k)/(temp(i,j,k)*RDGAS)
            end do

!----------------------------------------------------------------------
!    calculate buoyancy frequency. restrict the squared buoyancy 
!    frequency to be no smaller than bflim.
!----------------------------------------------------------------------
            do k=1,iz0 
              zbf(i,j,k) = (GRAV/temp(i,j,k))*(dtdz(i,j,k) + GRAV/CP_AIR)
              if (zbf(i,j,k) < bflim) then
                zbf(i,j,k) = sqrt(bflim)
              else 
                zbf(i,j,k) = sqrt(zbf(i,j,k))
              endif
            end do

!----------------------------------------------------------------------
!    if zbf is to be saved for netcdf output, the remaining vertical
!    levels must be initialized.
!----------------------------------------------------------------------
            if (id_bf_cgwd > 0) then
              zbf(i,j,iz0+1:) = 0.0
            endif

!----------------------------------------------------------------------
!    define an array of heights at model levels and an array containing
!    the zonal wind component.
!----------------------------------------------------------------------
            do k=1,iz0+1
              zzchm(i,j,k) = zfull(i,j,k)
            end do
            do k=1,iz0   
              zu(i,j,k) = uuu(i,j,k)
              zv(i,j,k) = vvv(i,j,k)
            end do

!----------------------------------------------------------------------
!    add an extra level above model top so that the gravity wave forcing
!    occurring between the topmost model level and the upper boundary
!    may be calculated. define variable values at the new top level as
!    follows: z - use delta z of layer just below; u - extend vertical 
!    gradient occurring just below; density - geometric mean; buoyancy 
!    frequency - constant across model top.
!----------------------------------------------------------------------
            zzchm(i,j,0) = zzchm(i,j,1) + zzchm(i,j,1) - zzchm(i,j,2)
            zu(i,j,0)    = 2.*zu(i,j,1) - zu(i,j,2)
            zv(i,j,0)    = 2.*zv(i,j,1) - zv(i,j,2)
            zden(i,j,0)  = zden(i,j,1)*zden(i,j,1)/zden(i,j,2)
            zbf(i,j,0)   = zbf(i,j,1)
          end do
        end do
      
!---------------------------------------------------------------------
!    pass the vertically-extended input arrays to gwfc. gwfc will cal-
!    culate the gravity-wave forcing and, if desired, an effective eddy 
!    diffusion coefficient at each level above the source level. output
!    is returned in the vertically-extended arrays gwfcng and ked_gwfc.
!    upon return move the output fields into model-sized arrays. 
!---------------------------------------------------------------------


       call gwfc (is, ie, js, je, source_level, source_amp,    &
                     zden, zu, zbf,zzchm, gwd_xtnd, ked_xtnd)

          gwfcng_x  (:,:,1:kmax) = gwd_xtnd(:,:,1:kmax  )
          ked_gwfc_x(:,:,1:kmax) = ked_xtnd(:,:,1:kmax  )

       call gwfc (is, ie, js, je, source_level, source_amp,    &
                     zden, zv, zbf,zzchm, gwd_ytnd, ked_ytnd)
          gwfcng_y  (:,:,1:kmax) = gwd_ytnd(:,:,1:kmax  )
          ked_gwfc_y(:,:,1:kmax) = ked_ytnd(:,:,1:kmax  )



!epg kill this stuff
!--------------------------------------------------------------------
!  if column diagnostics are desired, determine if any columns are on
!  this processor. if so, call column_diagnostics_header to write
!  out location and timestamp information. then output desired 
!  quantities to the diag_unit file.
!---------------------------------------------------------------------



!--------------------------------------------------------------------
!    store the gravity wave forcing into a processor-global array.
!-------------------------------------------------------------------
!wfc++ Not needed as calculate_ked is gone.
!!!   rjw   Not needed as we have eliminated restart files 
!!!rjw        gwd(is:ie,js:je,:) = gwfcng(:,:,:)
!wfc

!wfc--

!rjw          if (id_ked_cgwd > 0) then
!wfc++ iloc,jloc used.
!rjw            used = send_data (id_ked_cgwd, ked_gwfc, Time, iloc, jloc)
!wfc--
!rjw          endif

          if (id_kedx_cgwd > 0) then
            used = send_data (id_kedx_cgwd, ked_gwfc_x, Time, is, js, 1)
          endif

          if (id_kedy_cgwd > 0) then
            used = send_data (id_kedy_cgwd, ked_gwfc_y, Time, is, js, 1)
          endif



!--------------------------------------------------------------------
!    save any other netcdf file diagnostics that are desired.
!--------------------------------------------------------------------
        if (id_bf_cgwd > 0) then
!wfc++ iloc, jloc
!rjw          used = send_data (id_bf_cgwd,  zbf(:,:,1:), Time, iloc, jloc )
          used = send_data (id_bf_cgwd,  zbf(:,:,1:), Time, is, js )
!wfc--
        endif
! rjw        if (id_gwf_cgwd > 0) then
!wfc++ iloc, jloc
! rjw          used = send_data (id_gwf_cgwd, gwfcng, Time, iloc, jloc )
!wfc--
! rjw        endif

        if (id_gwfx_cgwd > 0) then
          used = send_data (id_gwfx_cgwd, gwfcng_x, Time, is, js, 1)
        endif
        if (id_gwfy_cgwd > 0) then
          used = send_data (id_gwfy_cgwd, gwfcng_y, Time, is, js, 1)
        endif



!--------------------------------------------------------------------
!    if this is not a timestep on which gravity wave forcing is to be 
!    calculated, retrieve the values calculated previously from storage
!    and return to the calling subroutine.
!--------------------------------------------------------------------
!wfc++ no alarms anymore? 
!!!rjw      else   ! (cgdrag_alarm <= 0)
!!!rjw        gwfcng(:,:,:) = gwd(is:ie,js:je,:)
!!!rjw     endif  ! (cgdrag_alarm <= 0)
!wfc--

!--------------------------------------------------------------------
!    increment the number of points processed on this time step, and 
!    if all points have now been processed and this was a calculation
!    step, reset cgdrag_alarm to indicate the time remaining before the
!    next calculation of gravity wave forcing.
!--------------------------------------------------------------------


!--------------------------------------------------------------------



end subroutine cg_drag_calc



!###################################################################

subroutine cg_drag_end

!--------------------------------------------------------------------
!    cg_drag_end is the destructor for cg_drag_mod.
!--------------------------------------------------------------------

!--------------------------------------------------------------------
!    local variables

      integer :: unit     ! unit for writing restart file


!wfc--

!---------------------------------------------------------------------
!    mark the module as uninitialized.
!---------------------------------------------------------------------
      module_is_initialized = .false.

!---------------------------------------------------------------------


end subroutine cg_drag_end




!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
!                     PRIVATE SUBROUTINES
!
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%




!#####################################################################

subroutine read_restart_file

!-------------------------------------------------------------------
!   read_restart_file reads the cg_drag_mod restart file.
!-------------------------------------------------------------------

!-------------------------------------------------------------------
!   local variables

      integer                 :: unit
      character(len=8)        :: chvers
      integer                 :: vers
      integer, dimension(5)   :: null
      integer                 :: old_time_step
      real                    :: secs_per_day = 86400.

!-------------------------------------------------------------------
!   local variables: 
!   
!       unit           unit number for nml file 
!       chvers         character representation of restart version 
!       vers           restart version 
!       null           array to hold restart version 1 control variables
!       old_time_step  cg_drag timestep used in previous model run [ s ]
!       secs_per_day   seconds in a day [ s ]
!
!---------------------------------------------------------------------


!--------------------------------------------------------------------
!    if cg_drag_offset is specified and is smaller than the time remain-
!    ing until the next calculation, modify the time remaining to be 
!    that offset time. the assumption is made that the restart was
!    written at 00Z.
!--------------------------------------------------------------------
      if (cg_drag_offset /= 0) then
        if (cgdrag_alarm > cg_drag_offset) then
          cgdrag_alarm = cg_drag_offset
        endif
      endif

!---------------------------------------------------------------------


end subroutine read_restart_file


!####################################################################

subroutine gwfc (is, ie, js, je, source_level, source_amp, rho, u,    &
                 bf, z, gwf, ked)

!-------------------------------------------------------------------
!    subroutine gwfc computes the gravity wave-driven-forcing on the
!    zonal wind given vertical profiles of wind, density, and buoyancy 
!    frequency. 
!    Based on version implemented in SKYHI -- 27 Oct 1998 by M.J. 
!    Alexander and L. Bruhwiler.
!-------------------------------------------------------------------

!-------------------------------------------------------------------
integer,                     intent(in)             :: is, ie, js, je
integer, dimension(:,:),     intent(in)             :: source_level
real,    dimension(:,:),     intent(in)             :: source_amp
real,    dimension(:,:,0:),  intent(in)             :: rho, u, bf, z
real,    dimension(:,:,0:),  intent(out)            :: gwf
!wfc++ remove obsolete code
!!!rjw  real,    dimension(:,:,0:),  intent(out), optional  :: ked
!wfc--
real,    dimension(:,:,0:),  intent(out)  :: ked

!-------------------------------------------------------------------
!  intent(in) variables:
!
!      is, ie, js, je   starting/ending subdomain i,j indices of data
!                       in the physics_window being integrated
!      source_level     k index of model level serving as gravity wave
!                       source
!      source_amp     amplitude of  gravity wave source
!                       
!      rho              atmospheric density [ kg/m^3 ] 
!      u                zonal wind component [ m/s ]
!      bf               buoyancy frequency [ /s ]
!      z                height of model levels  [ m ]
!
!  intent(out) variables:
!
!      gwf              gravity wave forcing in u equation  [ m/s^2 ]
!
!  intent(out), optional variables:
!
!      ked              eddy diffusion coefficient from gravity wave 
!                       forcing [ m^2/s ]
!
!------------------------------------------------------------------

!------------------------------------------------------------------
!  local variables

      real,    dimension (0:size(u,3)-1 ) ::       &
                                   wv_frcng, diff_coeff, c0mu, dz,    &
                                   fac, omc
      integer, dimension (nc) ::   msk
      real   , dimension (nc) ::   c0mu0, B0
      real                    ::   fm, fe, Hb, alp2, Foc, c, test, rbh,&
                                   eps, Bsum
      integer                 ::   iz0 
      integer                 ::   i, j, k, ink, n
      real                    ::   ampl
!------------------------------------------------------------------
!  local variables:
! 
!      wv_frcng    gravity wave forcing tendency [ m/s^2 ]
!      diff_coeff  eddy diffusion coefficient [ m2/s ]
!      c0mu        difference between phase speed of wave n and u 
!                  [ m/s ]
!      dz          delta z between model levels [ m ]
!      fac         factor used in determining if wave is breaking 
!                  [ s/m ]
!      omc         critical frequency that marks total internal 
!                  reflection  [ /s ]
!      msk         indicator as to whether wave n is still propagating 
!                  upwards (msk=1), or has been removed from the 
!                  spectrum because of breaking or reflection (msk=0)
!      c0mu0       difference between phase speed of wave n and u at the
!                  source level [ m/s ]
!      B0          wave momentum flux amplitude for wave n [ (m/s)^2 ]
!      fm          used to sum up momentum flux from all waves n 
!                  deposited at a level [ (m/s)^2 ]
!      fe          used to sum up contributions to diffusion coefficient
!                  from all waves n at a level [ (m/s)^3 ]
!      Hb          density scale height [ m ]
!      alp2        scale height factor: 1/(2*Hb)**2  [ /m^2 ]
!      Foc         wave breaking threshold [ s/m ]
!      c           wave phase speed used in defining wave momentum flux
!                  amplitude [ m/s ]
!      test        condition defining internal reflection [ /s ]
!      rbh         atmospheric density at half-level (geometric mean)
!                  [ kg/m^3 ]
!      eps         intermittency factor
!      Bsum        total mag of gravity wave momentum flux at source 
!                  level, divided by the density  [ m^2/s^2 ]
!      iz0         source level vertical index for the given column
!      i,j,k       spatial do loop indices
!      ink         wavenumber loop index 
!      n           phase speed loop index 
!      ampl        phase speed loop index 
!
!--------------------------------------------------------------------

!-------------------------------------------------------------------
!    initialize the output arrays. these will hold values at each 
!    (i,j,k) point, summed over the wavelengths and phase speeds
!    defining the gravity wave spectrum.
!-------------------------------------------------------------------
      gwf = 0.0
!wfc++ remove obsolete code
!!!rjw      if (present(ked)) then
!wfc--
        ked = 0.0
!wfc++ remove obsolete code
!!!rjw      endif
!wfc--

      do j=1,size(u,2)
        do i=1,size(u,1)  
          iz0 = source_level(i,j)
          ampl= source_amp(i,j)

!--------------------------------------------------------------------
!    define wave momentum flux (B0) at source level for each phase 
!    speed n, and the sum over all phase speeds (Bsum), which is needed 
!    to calculate the intermittency. 
!-------------------------------------------------------------------
          Bsum = 0.
          do n=1,nc
            c0mu0(n) = c0(n) - u(i,j,iz0)   

!---------------------------------------------------------------------
!    when the wave phase speed is same as wind speed, there is no
!    momentum flux.
!---------------------------------------------------------------------
            if (c0mu0(n) == 0.0)  then
              B0(n) = 0.0
            else 

!---------------------------------------------------------------------
!    define wave momentum flux at source level for phase speed n. Add
!    the contribution from this phase speed to the previous sum.
!---------------------------------------------------------------------
              c = c0(n)*flag + c0mu0(n)*(1 - flag)
              if (c0mu0(n) < 0.0) then
                B0(n) = -1.0*(Bw*exp(-alog(2.0)*(c/cw)**2) +    &
                              Bn*exp(-alog(2.0)*(c/cn)**2))
              else 
                B0(n) = (Bw*exp(-alog(2.0)*(c/cw)**2)  +  &
                         Bn*exp(-alog(2.0)*(c/cn)**2))
              endif
              Bsum = Bsum + abs(B0(n))
            endif
          end do

!---------------------------------------------------------------------
!    define the intermittency factor eps. the factor of 1.5 is currently
!    unexplained.
!---------------------------------------------------------------------
          if (Bsum == 0.0) then
            call error_mesg ('cg_drag_mod', &
               ' zero flux input at source level', FATAL)
          endif
!!          eps = (Bt_0*1.5/nk)/Bsum
          eps = (ampl*1.5/nk)/Bsum

!--------------------------------------------------------------------
!    loop over the nk different wavelengths in the spectrum.
!--------------------------------------------------------------------
          do ink=1,nk   ! wavelength loop

!----------------------------------------------------------------------
!    define variables needed at levels above the source level.
!---------------------------------------------------------------------
            do k=0,iz0
              fac(k) = 0.5*(rho(i,j,k)/rho(i,j,iz0))*kwv(ink)/bf(i,j,k)
            end do

            do k=0,iz0 
              dz(k) = z(i,j,k) - z(i,j,k+1)
              Hb = -(dz(k))/alog(rho(i,j,k)/rho(i,j,k+1))
              alp2 = 0.25/(Hb*Hb)
              omc(k) = sqrt((bf(i,j,k)*bf(i,j,k)*k2(ink))/    &
                            (k2(ink) + alp2))
            end do

!---------------------------------------------------------------------
!    initialize a flag which will indicate which waves are still 
!    propagating upwards.
!---------------------------------------------------------------------
            msk = 1

!----------------------------------------------------------------------
!    integrate upwards from the source level.  define variables over 
!    which to sum the deposited flux and effective eddy diffusivity 
!    from all waves breaking at a given level.
!----------------------------------------------------------------------
            do k=iz0, 0, -1
              fm = 0.
              fe = 0.
              do n=1,nc     ! phase speed loop

!----------------------------------------------------------------------
!    check only those waves which are still propagating, i.e., msk = 1.
!----------------------------------------------------------------------
                if (msk(n) == 1) then
                  c0mu(k) = c0(n) - u(i,j,k)

!----------------------------------------------------------------------
!    if phase speed matches the wind speed, remove c0(n) from the 
!    set of propagating waves.
!----------------------------------------------------------------------
                  if (c0mu(k) == 0.) then
                    msk(n) = 0
                  else

!---------------------------------------------------------------------
!    define the criterion which determines if wave is reflected at this 
!    level (test).
!---------------------------------------------------------------------
                    test = abs(c0mu(k))*kwv(ink) - omc(k)
                    if (test >= 0.0) then

!---------------------------------------------------------------------
!    wave has undergone total internal reflection. remove it from the
!    propagating set.
!---------------------------------------------------------------------
                      msk(n) = 0
                    else 

!---------------------------------------------------------------------
!    if wave is  not reflected at this level, determine if it is 
!    breaking at this level (Foc >= 0),  or if wave speed relative to 
!    windspeed has changed sign from its value at the source level 
!    (c0mu0(n)*c0mu <= 0). if it is above the source level and is
!    breaking, then add its momentum flux to the accumulated sum at 
!    this level, and increase the effective diffusivity accordingly. 
!    set flag to remove phase speed c0(n) from the set of active waves
!    moving upwards to the next level.
!---------------------------------------------------------------------
                      Foc = B0(n)/(c0mu(k) )**3 - fac(k)
                      if ((Foc >= 0.0) .or.     &
                              (c0mu0(n)*c0mu(k)  <= 0.0)) then
                        msk(n) = 0
                        if (k  < iz0) then
                          fm = fm + B0(n)
!wfc++ remove obsolete code
!!!rjw                          if (calculate_ked) then
!wfc--
                            fe = fe + c0mu(k)*B0(n)
!wfc++ remove obsolete code
!!!rjw                          endif
!wfc--
                        endif
                      endif                      
                    endif   ! (test >= 0.0)
                  endif ! (c0mu == 0.0)
                endif   ! (msk == 1)
              end do  ! phase speed loop

!----------------------------------------------------------------------
!    compute the gravity wave momentum flux forcing and eddy 
!    diffusion coefficient obtained across the entire wave spectrum
!    at this level.
!----------------------------------------------------------------------
              if ( k < iz0) then
                rbh = sqrt(rho(i,j,k)*rho(i,j,k+1))
                wv_frcng(k) = ( rho(i,j,iz0)/rbh)*fm*eps/dz(k)
                wv_frcng(k+1) =  0.5*(wv_frcng(k+1) + wv_frcng(k))
!wfc++ remove obsolete code
!!!rjw                if (calculate_ked) then
!wfc--
                  diff_coeff(k) = (rho(i,j,iz0)/rbh)*fe*eps/(dz(k)*   &
                            bf(i,j,k)*bf(i,j,k))
                  diff_coeff(k+1) = 0.5*(diff_coeff(k+1) +    &
                                         diff_coeff(k))
!wfc++ remove obsolete code
!!!rjw                endif
!wfc--
              else 
                wv_frcng(iz0) = 0.0
!wfc++ remove obsolete code
!!!rjw                if (calculate_ked) then
!wfc--
                  diff_coeff(iz0) = 0.0
!wfc++ remove obsolete code
!!!rjw                endif
!wfc--
              endif
            end do  ! (k loop)               

!---------------------------------------------------------------------
!    increment the total forcing at each point with that obtained from
!    the set of waves with the current wavenumber.
!---------------------------------------------------------------------
            do k=0,iz0      
              gwf(i,j,k) = gwf(i,j,k) + wv_frcng(k)
!wfc++ remove obsolete code
!!!rjw              if (present(ked)) then
!wfc--
                ked(i,j,k) = ked(i,j,k) + diff_coeff(k)
!wfc++ remove obsolete code
!!!rjw              endif
!wfc--
            end do              
          end do   ! wavelength loop
        end do  ! i loop                      
      end do   ! j loop                 

!--------------------------------------------------------------------



end subroutine gwfc



!####################################################################


                    end module cg_drag_mod

