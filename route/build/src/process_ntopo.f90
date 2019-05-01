module process_ntopo

! data types
USE nrtype,    only : i4b,dp,lgt          ! variable types, etc.
USE nrtype,    only : strLen              ! length of characters
USE dataTypes, only : var_ilength         ! integer type:          var(:)%dat
USE dataTypes, only : var_dlength,dlength ! double precision type: var(:)%dat, or dat

! global vars
USE public_var, only : idSegOut           ! ID for stream segment at the bottom of the subset

! options
USE public_var, only : topoNetworkOption  ! option to compute network topology
USE public_var, only : computeReachList   ! option to compute reach list
USE public_var, only : hydGeometryOption  ! option to obtain routing parameters
USE public_var, only : routOpt            ! option for desired routing method
USE public_var, only : allRoutingMethods  ! option for routing methods - all the methods
USE public_var, only : kinematicWave      ! option for routing methods - kinematic wave only
USE public_var, only : impulseResponseFunc! option for routing methods - IRF only

! named variables
USE globalData, only : true,false         ! named integers for true/false

! named variables
USE var_lookup,only:ixSEG                 ! index of variables for the stream segments
USE var_lookup,only:ixNTOPO               ! index of variables for the network topology

! common variables
USE public_var, only : compute            ! compute given variable
USE public_var, only : doNotCompute       ! do not compute given variable
USE public_var, only : readFromFile       ! read given variable from a file
USE public_var, only : realMissing        ! missing value for real
USE public_var, only : integerMissing     ! missing value for integers

implicit none

! privacy -- everything private unless declared explicitly
private
public::augment_ntopo
public::put_data_struct

contains

 ! *********************************************************************
 ! public subroutine: augment river network data
 ! *********************************************************************
 subroutine augment_ntopo(&
                  ! input: model control
                  nHRU,             & ! number of HRUs
                  nSeg,             & ! number of stream segments
                  ! inout: populate data structures
                  structHRU,        & ! ancillary data for HRUs
                  structSEG,        & ! ancillary data for stream segments
                  structHRU2seg,    & ! ancillary data for mapping hru2basin
                  structNTOPO,      & ! ancillary data for network toopology
                  ! output:
                  ierr, message,    & ! error control
                  ! optional output:
                  tot_hru,          & ! total number of all the upstream hrus for all stream segments
                  tot_upseg,        & ! total number of immediate upstream segments for all  stream segments
                  tot_upstream,     & ! total number of all the upstream segments for all stream segments
                  tot_uh,           & ! total number of unit hydrograph from all the stream segments
                  ixHRU_desired,    & ! indices of desired hrus
                  ixSeg_desired     ) ! indices of desired reaches

 ! external subroutines/data
 ! network topology routine
 use network_topo,     only:hru2segment           ! get the mapping between HRUs and segments
 use network_topo,     only:up2downSegment        ! get the mapping between upstream and downstream segments
 use network_topo,     only:reachOrder            ! define the processing order
 use network_topo,     only:reach_list            ! reach list
 use network_topo,     only:reach_mask            ! identify all reaches upstream of a given reach
 ! Routing parameter estimation routine
 use routing_param,    only:make_uh               ! construct reach unit hydrograph
 ! routing spatial constant parameters
 use globalData,       only:mann_n, wscale        ! KWT routing parameters (Transfer function parameters)
 use globalData,       only:velo, diff            ! IRF routing parameters (Transfer function parameters)

 USE public_var, only : dt                        ! simulation time step [sec]

 ! This subroutine populate river network topology data strucutres
 implicit none
 ! output: model control
 integer(i4b),       intent(in)                    :: nHRU             ! number of HRUs
 integer(i4b),       intent(in)                    :: nSeg             ! number of stream segments
 ! inout: populate data structures
 type(var_dlength), intent(inout), allocatable     :: structHRU(:)     ! HRU properties
 type(var_dlength), intent(inout), allocatable     :: structSEG(:)     ! stream segment properties
 type(var_ilength), intent(inout), allocatable     :: structHRU2seg(:) ! HRU-to-segment mapping
 type(var_ilength), intent(inout), allocatable     :: structNTOPO(:)   ! network topology
 ! output: error control
 integer(i4b)      , intent(out)                   :: ierr             ! error code
 character(*)      , intent(out)                   :: message          ! error message
 ! optional output:
 integer(i4b), optional, intent(out)               :: tot_upstream     ! total number of all of the upstream stream segments for all stream segments
 integer(i4b), optional, intent(out)               :: tot_upseg        ! total number of immediate upstream segments for all  stream segments
 integer(i4b), optional, intent(out)               :: tot_hru          ! total number of all the upstream hrus for all stream segments
 integer(i4b), optional, intent(out)               :: tot_uh           ! total number of unit hydrograph from all the stream segments
 integer(i4b), optional, intent(out),  allocatable :: ixHRU_desired(:) ! indices of desired hrus
 integer(i4b), optional, intent(out),  allocatable :: ixSeg_desired(:) ! indices of desired reaches
 ! --------------------------------------------------------------------------------------------------------------
 ! local variables
 character(len=strLen)                             :: cmessage             ! error message of downwind routine
 integer(i4b)                                      :: tot_upstream_tmp     ! temporal storage for tot_upstream
 integer(i4b)                                      :: tot_upseg_tmp        ! temporal storage tot_upseg_tmp
 integer(i4b)                                      :: tot_hru_tmp          ! temporal storage tot_hru_tmp
 integer(i4b)                                      :: tot_uh_tmp           ! temporal storage tot_uh_tmp
 integer(i4b), allocatable                         :: ixHRU_desired_tmp(:) ! temporal storage ixHRU_desired_tmp
 integer(i4b), allocatable                         :: ixSeg_desired_tmp(:) ! temporal storage ixSeg_desired_tmp
 integer(i4b)                                      :: iSeg                 ! indices for stream segment
 integer(i4b), parameter                           :: maxUpstreamFile=10000000 ! 10 million: maximum number of upstream reaches to enable writing
 integer*8                                         :: time0,time1          ! for timing
 real(dp)     , allocatable                        :: seg_length(:)        ! temporal array for segment length
 type(dlength), allocatable                        :: temp_dat(:)          ! temporal storage for dlength data structure

 ! initialize error control
 ierr=0; message='augment_ntopo/'

 ! initialize times
 call system_clock(time0)

 ! ---------- get the mapping between HRUs and segments ------------------------------------------------------

 ! check the need to compute network topology
 if(topoNetworkOption==compute)then

  ! get the mapping between HRUs and basins
  call hru2segment(&
                   ! input
                   nHRU,          & ! input: number of HRUs
                   nSeg,          & ! input: number of stream segments
                   ! input-output: data structures
                   structHRU,     & ! ancillary data for HRUs
                   structSEG,     & ! ancillary data for stream segments
                   structHRU2seg, & ! ancillary data for mapping hru2basin
                   structNTOPO,   & ! ancillary data for network toopology
                   ! output
                   tot_hru_tmp,   & ! output: total number of all the upstream hrus for all stream segments
                   ierr, cmessage)  ! output: error control
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif


  ! get timing
  call system_clock(time1)
  !write(*,'(a,1x,i20)') 'after hru2segment: time = ', time1-time0
  !print*, trim(message)//'PAUSE : '; read(*,*)

 endif  ! if need to compute network topology

 ! ---------- get the mapping between upstream and downstream segments ---------------------------------------

 ! check the need to compute network topology
 if(topoNetworkOption==compute)then

  ! get the mapping between upstream and downstream segments
  call up2downSegment(&
                      ! input
                      nSeg,          & ! input: number of stream segments
                      ! input-output: data structures
                      structNTOPO,   & ! ancillary data for network toopology
                      ! output
                      tot_upseg_tmp, & ! output: sum of immediate upstream segments
                      ierr, cmessage)  ! output: error control
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  ! get timing
  call system_clock(time1)
  !write(*,'(a,1x,i20)') 'after up2downSegment: time = ', time1-time0
  !print*, trim(message)//'PAUSE : '; read(*,*)

 endif  ! if need to compute network topology

 ! ---------- get the processing order -----------------------------------------------------------------------

 ! check the need to compute network topology
 if(topoNetworkOption==compute)then

  ! defines the processing order for the individual stream segments in the river network
  call REACHORDER(nSeg,         &   ! input:        number of reaches
                  structNTOPO,  &   ! input:output: network topology
                  ierr, cmessage)   ! output:       error control
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  ! get timing
  call system_clock(time1)
  !write(*,'(a,1x,i20)') 'after reachOrder: time = ', time1-time0
  !print*, trim(message)//'PAUSE : '; read(*,*)

 endif  ! if need to compute network topology

 ! ---------- get the list of all upstream reaches above a given reach ---------------------------------------

 ! get the list of all upstream reaches above a given reach
 call reach_list(&
                 ! input
                 nSeg,                        & ! Number of reaches
                 (computeReachList==compute), & ! flag to compute the reach list
                 structNTOPO,                 & ! Network topology
                 ! output
                 structSEG,                   & ! input: ancillary data for stream segments
                 tot_upstream_tmp,            & ! Total number of upstream reaches for all reaches
                 ierr, cmessage)                ! Error control
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 ! get timing
 call system_clock(time1)
 !write(*,'(a,1x,i20)') 'after reach_list: time = ', time1-time0
 !print*, trim(message)//'PAUSE : '; read(*,*)

 ! ---------- Compute routing parameters  --------------------------------------------------------------------

 ! compute hydraulic geometry (width and Manning's "n")
 if(hydGeometryOption==compute)then

  ! (hydraulic geometry only needed for the kinematic wave method)
  if (routOpt==allRoutingMethods .or. routOpt==kinematicWave) then
   do iSeg=1,nSeg
    structSEG(iSeg)%var(ixSEG%width)%dat(1) = wscale * sqrt(structSEG(iSeg)%var(ixSEG%totalArea)%dat(1))  ! channel width (m)
    structSEG(iSeg)%var(ixSEG%man_n)%dat(1) = mann_n                                                      ! Manning's "n" paramater (unitless)
   end do
  end if

 endif  ! computing hydraulic geometry

 ! get the channel unit hydrograph
 if(topoNetworkOption==compute)then

  ! (channel unit hydrograph is only needed for the impulse response function)
  if (routOpt==allRoutingMethods .or. routOpt==impulseResponseFunc) then

   ! extract the length information from the structure and place it in a vector
   allocate(seg_length(nSeg), stat=ierr, errmsg=cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage)//': seg_length'; return; endif
   forall(iSeg=1:nSeg) seg_length(iSeg) = structSEG(iSeg)%var(ixSEG%length)%dat(1)

   ! compute lag times in the channel unit hydrograph
   call make_uh(seg_length, dt, velo, diff, temp_dat, ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

   ! put the lag times in the data structures
   tot_uh_tmp = 0
   do iSeg=1,nSeg
    allocate(structSEG(iSeg)%var(ixSEG%timeDelayHist)%dat(size(temp_dat(iSeg)%dat)), stat=ierr, errmsg=cmessage)
    if(ierr/=0)then; message=trim(message)//trim(cmessage)//': structSEG%var(ixSEG%uh)%dat'; return; endif
    structSEG(iSeg)%var(ixSEG%timeDelayHist)%dat(:) = temp_dat(iSeg)%dat(:)
    tot_uh_tmp = tot_uh_tmp+size(temp_dat(iSeg)%dat)
   enddo

  endif ! if using the impulse response function

 endif ! if there is a need to compute the channel unit hydrograph

 ! ---------- get the mask of all upstream reaches above a given reach ---------------------------------------

 ! get the mask of all upstream reaches above a given reach
 call reach_mask(&
                 ! input
                 idSegOut,          &  ! input: reach index
                 structNTOPO,       &  ! input: network topology structures
                 structSeg,         &  ! input: river reach properties
                 nHRU,              &  ! input: number of HRUs
                 nSeg,              &  ! input: number of reaches
                 ! output: updated dimensions
                 tot_hru_tmp,       &  ! input+output: total number of all the upstream hrus for all stream segments
                 tot_upseg_tmp,     &  ! input+output: sum of immediate upstream segments
                 tot_upstream_tmp,  &  ! input+output: total number of upstream reaches for all reaches
                 tot_uh_tmp,        &  ! input+output: total number of unit hydrograph dimensions
                 ! output: dimension masks
                 ixHRU_desired_tmp, &  ! output: indices of desired hrus
                 ixSeg_desired_tmp, &  ! output: indices of desired reaches
                 ! output: error control
                 ierr, cmessage )  ! output: error control
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 ! get timing
 call system_clock(time1)
 !write(*,'(a,1x,i20)') 'after reach_mask: time = ', time1-time0
 !print*, trim(message)//'PAUSE : '; read(*,*)

 ! for optional output
 if (present(tot_hru))       tot_hru=tot_hru_tmp
 if (present(tot_upseg))     tot_upseg=tot_upseg_tmp
 if (present(tot_upstream))  tot_upstream=tot_upstream_tmp
 if (present(tot_uh))        tot_uh=tot_uh_tmp
 if (present(ixSeg_desired)) then
   allocate(ixSeg_desired(size(ixSeg_desired_tmp)), stat=ierr)
   if(ierr/=0)then; message=trim(message)//'problem in allocating [isSeg_desire]'; return; endif
   ixSeg_desired=ixSeg_desired_tmp
 endif
 if (present(ixHRU_desired)) then
   allocate(ixHRU_desired(size(ixHRU_desired_tmp)), stat=ierr)
   if(ierr/=0)then; message=trim(message)//'problem in allocating [ixHRU_desired]'; return; endif
   ixHRU_desired=ixHRU_desired_tmp
 endif

end subroutine augment_ntopo

 ! *********************************************************************
 ! public subroutine: populate old data strucutures
 ! *********************************************************************
 ! ---------- temporary code: populate old data structures --------------------------------------------------
 subroutine put_data_struct(nSeg, structSEG, structNTOPO, &
                            RPARAM_in, NETOPO_in , ierr, message)
  ! saved global data
  use dataTypes,     only : RCHPRP             ! Reach parameters
  use dataTypes,     only : RCHTOPO            ! Network topology
  use globalData,    only : fshape, tscale     ! basin IRF routing parameters (Transfer function parameters)
  USE public_var,    only : min_slope          ! minimum slope
  USE public_var,    only : dt                 ! simulation time step [sec]
  ! external subroutines
  use routing_param, only : basinUH            ! construct basin unit hydrograph
  implicit none
  ! input
  integer(i4b)                , intent(in)       :: nSeg             ! number of stream segments
  type(var_dlength)           , intent(in)       :: structSEG(:)     ! stream segment properties
  type(var_ilength)           , intent(in)       :: structNTOPO(:)   ! network topology
  ! output data structure
  type(RCHPRP)  , allocatable , intent(out)      :: RPARAM_in(:)     ! Reach Parameters
  type(RCHTOPO) , allocatable , intent(out)      :: NETOPO_in(:)     ! River Network topology
  ! output: error control
  integer(i4b)                , intent(out)      :: ierr             ! error code
  character(*)                , intent(out)      :: message          ! error message
  ! local varialbles
  character(len=strLen)                          :: cmessage         ! error message of downwind routine
  integer(i4b)                                   :: nUps             ! number of upstream segments for a segment
  integer(i4b)                                   :: iSeg,iUps        ! loop indices

  ! initialize error control
  ierr=0; message='put_data_struct/'

  ! get lag times in the basin unit hydrograph (not sure this is right place...)
  call basinUH(dt, fshape, tscale, ierr, cmessage)
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  ! allocate space
  allocate(RPARAM_in(nSeg), NETOPO_in(nSeg), stat=ierr)
  if(ierr/=0)then; message=trim(message)//'unable to allocate space for old data structures'; return; endif

  ! loop through stream segments
  do iSeg=1,nSeg

   ! print progress
   if(mod(iSeg,1000000)==0) print*, 'Copying to the old data structures: iSeg, nSeg = ', iSeg, nSeg

   ! ----- reach parameters -----

   ! copy data into the reach parameter structure
   RPARAM_in(iSeg)%RLENGTH =     structSEG(iSeg)%var(ixSEG%length)%dat(1)
   RPARAM_in(iSeg)%R_SLOPE = max(structSEG(iSeg)%var(ixSEG%slope)%dat(1), min_slope)
   RPARAM_in(iSeg)%R_MAN_N =     structSEG(iSeg)%var(ixSEG%man_n)%dat(1)
   RPARAM_in(iSeg)%R_WIDTH =     structSEG(iSeg)%var(ixSEG%width)%dat(1)

   ! compute variables
   RPARAM_in(iSeg)%BASAREA = structSEG(iSeg)%var(ixSEG%basArea)%dat(1)
   RPARAM_in(iSeg)%UPSAREA = structSEG(iSeg)%var(ixSEG%upsArea)%dat(1)
   RPARAM_in(iSeg)%TOTAREA = structSEG(iSeg)%var(ixSEG%totalArea)%dat(1)

   ! NOT USED: MINFLOW -- minimum environmental flow
   RPARAM_in(iSeg)%MINFLOW = structSEG(iSeg)%var(ixSEG%minFlow)%dat(1)

   ! ----- network topology -----

   ! reach indices
   NETOPO_in(iSeg)%REACHIX = structNTOPO(iSeg)%var(ixNTOPO%segIndex)%dat(1)     ! reach index (1, 2, 3, ..., nSeg)
   NETOPO_in(iSeg)%REACHID = structNTOPO(iSeg)%var(ixNTOPO%segId)%dat(1)        ! reach ID (unique reach identifier)

   ! downstream reach indices
   NETOPO_in(iSeg)%DREACHI = structNTOPO(iSeg)%var(ixNTOPO%downSegIndex)%dat(1) ! Immediate Downstream reach index
   NETOPO_in(iSeg)%DREACHK = structNTOPO(iSeg)%var(ixNTOPO%downSegId)%dat(1)    ! Immediate Downstream reach ID

   ! allocate space for immediate upstream reach indices
   nUps = size(structNTOPO(iSeg)%var(ixNTOPO%upSegIds)%dat)
   allocate(NETOPO_in(iSeg)%UREACHI(nUps), NETOPO_in(iSeg)%UREACHK(nUps), NETOPO_in(iSeg)%goodBas(nUps), stat=ierr)
   if(ierr/=0)then; message=trim(message)//'unable to allocate space for upstream structures'; return; endif

   ! populate immediate upstream data structures
   if(nUps>0)then
    do iUps=1,nUps   ! looping through upstream reaches
     NETOPO_in(iSeg)%UREACHI(iUps) = structNTOPO(iSeg)%var(ixNTOPO%upSegIndices)%dat(iUps)      ! Immediate Upstream reach indices
     NETOPO_in(iSeg)%UREACHK(iUps) = structNTOPO(iSeg)%var(ixNTOPO%upSegIds    )%dat(iUps)      ! Immediate Upstream reach Ids
     NETOPO_in(iSeg)%goodBas(iUps) = (structNTOPO(iSeg)%var(ixNTOPO%goodBasin)%dat(iUps)==true) ! "good" basin
    end do  ! Loop through upstream reaches
   endif

   ! define the reach order
   NETOPO_in(iSeg)%RHORDER = structNTOPO(iSeg)%var(ixNTOPO%rchOrder)%dat(1)  ! Processing sequence

   ! allocate space for contributing HRUs
   nUps = structNTOPO(iSeg)%var(ixNTOPO%nHRU)%dat(1)
   allocate(NETOPO_in(iSeg)%HRUID(nUps), NETOPO_in(iSeg)%HRUIX(nUps), NETOPO_in(iSeg)%HRUWGT(nUps), stat=ierr)
   if(ierr/=0)then; message=trim(message)//'unable to allocate space for contributing HRUs'; return; endif

   ! HRU2SEG topology
   if(nUps>0)then
     do iUps = 1, nUps
       NETOPO_in(iSeg)%HRUID(iUps) = structNTOPO(iSeg)%var(ixNTOPO%hruContribId)%dat(iUps)
       NETOPO_in(iSeg)%HRUIX(iUps) = structNTOPO(iSeg)%var(ixNTOPO%hruContribIx)%dat(iUps)
       NETOPO_in(iSeg)%HRUWGT(iUps) = structSEG(iSeg)%var(ixSEG%weight)%dat(iUps)
     end do  ! Loop through contributing HRU loop
   end if

   ! NOT USED: lake parameters
   NETOPO_in(iSeg)%LAKE_IX = integerMissing  ! Lake index (0,1,2,...,nlak-1)
   NETOPO_in(iSeg)%LAKE_ID = integerMissing  ! Lake ID (REC code?)
   NETOPO_in(iSeg)%BASULAK = realMissing     ! Area of basin under lake
   NETOPO_in(iSeg)%RCHULAK = realMissing     ! Length of reach under lake
   NETOPO_in(iSeg)%LAKINLT = .false.         ! .TRUE. if reach is lake inlet, .FALSE. otherwise
   NETOPO_in(iSeg)%USRTAKE = .false.         ! .TRUE. if user takes from reach, .FALSE. otherwise

   ! NOT USED: Location (available in the input files)
   NETOPO_in(iSeg)%RCHLAT1 = realMissing     ! Start latitude
   NETOPO_in(iSeg)%RCHLAT2 = realMissing     ! End latitude
   NETOPO_in(iSeg)%RCHLON1 = realMissing     ! Start longitude
   NETOPO_in(iSeg)%RCHLON2 = realMissing     ! End longitude

   ! reach unit hydrograph
   if (routOpt==allRoutingMethods .or. routOpt==impulseResponseFunc) then
     allocate(NETOPO_in(iSeg)%UH(size(structSEG(iSeg)%var(ixSEG%timeDelayHist)%dat)), stat=ierr, errmsg=cmessage)
     if(ierr/=0)then; message=trim(message)//trim(cmessage)//': NETOPO_in(iSeg)%UH'; return; endif
     NETOPO_in(iSeg)%UH(:) =  structSEG(iSeg)%var(ixSEG%timeDelayHist)%dat(:)
   end if

   ! upstream reach list
   allocate(NETOPO_in(iSeg)%RCHLIST(size(structNTOPO(iSeg)%var(ixNTOPO%allUpSegIndices)%dat)), stat=ierr, errmsg=cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage)//': NETOPO_in(iSeg)%RCHLIST'; return; endif
   NETOPO_in(iSeg)%RCHLIST(:) =  structNTOPO(iSeg)%var(ixNTOPO%allUpSegIndices)%dat(:)

  end do  ! looping through stream segments

 end subroutine put_data_struct

end module process_ntopo
