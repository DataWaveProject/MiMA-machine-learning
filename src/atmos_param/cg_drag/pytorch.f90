module cg_drag_ML_mod

use constants_mod, only:  RADIAN

! #ML
! Imports primitives used to interface with C
use, intrinsic :: iso_c_binding, only: c_int64_t, c_float, c_char, c_null_char, c_ptr, c_loc
! Import library for interfacing with PyTorch
use ftorch

!-------------------------------------------------------------------

implicit none
private

public    cg_drag_ML_init, cg_drag_ML_end, cg_drag_ML

!--------------------------------------------------------------------
!   data used in this module
!
!--------------------------------------------------------------------
!   model    ML model type bound to python
!
!--------------------------------------------------------------------

type(torch_module) :: model


!--------------------------------------------------------------------
!--------------------------------------------------------------------

contains

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
!                      PUBLIC SUBROUTINES
!
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


!####################################################################

subroutine cg_drag_ML_init(model_path)

  !-----------------------------------------------------------------
  !    cg_drag_ML_init is called from cg_drag_init and initialises
  !    anything required for the ML calculation of cg_drag such as
  !    an ML model
  !
  !-----------------------------------------------------------------
  
  !-----------------------------------------------------------------
  !    intent(in) variables:
  !
  !       model_path    full filepath to the model
  !
  !-----------------------------------------------------------------
  character(len=1024), intent(in)        :: model_path
  
  !-----------------------------------------------------------------
  
  ! Initialise the ML model to be used
  model = torch_module_load(trim(model_path)//c_null_char)

end subroutine cg_drag_ML_init


!####################################################################

subroutine cg_drag_ML_end

  !-----------------------------------------------------------------
  !    cg_drag_ML_end is called from cg_drag_end and is a destructor
  !    for anything used in the ML part of calculating cg_drag such
  !    as an ML model.
  !
  !-----------------------------------------------------------------
  
  ! destroy the model
  call torch_module_delete(model)

end subroutine cg_drag_ML_end


!####################################################################

subroutine cg_drag_ML(uuu, vvv, psfc, lat, gwfcng_x, gwfcng_y)

  !-----------------------------------------------------------------
  !    cg_drag_ML returns the x and y gravity wave drag forcing
  !    terms following calculation using an external neural net.
  !
  !-----------------------------------------------------------------
  
  !-----------------------------------------------------------------
  !    intent(in) variables:
  !
  !       is,js    starting subdomain i,j indices of data in 
  !                the physics_window being integrated
  !       uuu,vvv  arrays of model u and v wind
  !       psfc     array of model surface pressure
  !       lat      array of model latitudes at cell boundaries [radians]
  !
  !    intent(out) variables:
  !
  !       gwfcng_x time tendency for u eqn due to gravity-wave forcing
  !                [ m/s^2 ]
  !       gwfcng_y time tendency for v eqn due to gravity-wave forcing
  !                [ m/s^2 ]
  !
  !-----------------------------------------------------------------
  
  real, dimension(:,:,:), intent(in)    :: uuu, vvv
  real, dimension(:,:),   intent(in)    :: lat, psfc
  
  real, dimension(:,:,:), intent(out), target   :: gwfcng_x, gwfcng_y
  
  !-----------------------------------------------------------------

  !-------------------------------------------------------------------
  !    local variables:
  !
  !       dtdz          temperature lapse rate [ deg K/m ]
  !
  !---------------------------------------------------------------------

  real, dimension(:,:), allocatable  :: uuu_flattened, vvv_flattened
  real, dimension(:,:), allocatable, target  :: uuu_reshaped, vvv_reshaped
  real, dimension(:), allocatable, target    :: lat_reshaped, psfc_reshaped

  integer :: imax, jmax, kmax, j
  ! real, parameter :: rad2deg = 180.0/(4.0*ATAN(1.0))
  ! real, parameter :: rad2deg = 180.0/PI

  integer(c_int), parameter :: dims_2D = 2
  integer(c_int64_t) :: shape_2D(dims_2D)
  integer(c_int), parameter :: dims_1D = 2
  integer(c_int64_t) :: shape_1D(dims_1D)
  integer(c_int), parameter :: dims_out = 2
  integer(c_int64_t) :: shape_out(dims_out)

  ! Set up types of input and output data and the interface with C
  type(torch_tensor) :: gwfcng_x_tensor, gwfcng_y_tensor
  
  integer(c_int), parameter :: n_inputs = 3
  type(torch_tensor), dimension(n_inputs), target :: model_input_arr
  
  !----------------------------------------------------------------

  ! reshape tensors as required
  imax = size(uuu, 1)
  jmax = size(uuu, 2)
  kmax = size(uuu, 3)

  ! Note that the '1D' tensor has 2 dimensions, one of which is size 1
  shape_2D = (/ imax*jmax, kmax /)
  shape_1D = (/ imax*jmax, 1 /)

  ! flatten data (nlat, nlon, n) --> (nlat*nlon, n)
  allocate( uuu_flattened(imax*jmax, kmax) )
  allocate( vvv_flattened(imax*jmax, kmax) )
  allocate( uuu_reshaped(kmax, imax*jmax) )
  allocate( vvv_reshaped(kmax, imax*jmax) )
  allocate( lat_reshaped(imax*jmax) )
  allocate( psfc_reshaped(imax*jmax) )

  do j=1,jmax
      uuu_flattened((j-1)*imax+1:j*imax,:) = uuu(:,j,:)
      vvv_flattened((j-1)*imax+1:j*imax,:) = vvv(:,j,:)
      lat_reshaped((j-1)*imax+1:j*imax) = lat(:,j)*RADIAN
      psfc_reshaped((j-1)*imax+1:j*imax) = psfc(:,j)/100
  end do

  uuu_reshaped = TRANSPOSE(uuu_flattened)
  vvv_reshaped = TRANSPOSE(vvv_flattened)

  ! Create input/output tensors from the above arrays
  model_input_arr(1) = torch_tensor_from_blob(c_loc(uuu_reshaped), dims_2D, shape_2D, torch_kFloat64, torch_kCPU)
  model_input_arr(2) = torch_tensor_from_blob(c_loc(lat_reshaped), dims_1D, shape_1D, torch_kFloat64, torch_kCPU)
  model_input_arr(3) = torch_tensor_from_blob(c_loc(psfc_reshaped), dims_1D, shape_1D, torch_kFloat64, torch_kCPU)

  gwfcng_x_tensor = torch_tensor_from_blob(c_loc(gwfcng_x), dims_out, shape_out, torch_kFloat64, torch_kCPU)
  ! Load model and Infer zonal
  call torch_module_forward(model, model_input_arr, n_inputs, gwfcng_x_tensor)
  
  model_input_arr(1) = torch_tensor_from_blob(c_loc(vvv_reshaped), dims_2D, shape_2D, torch_kFloat64, torch_kCPU)
  gwfcng_y_tensor = torch_tensor_from_blob(c_loc(gwfcng_y), dims_out, shape_out, torch_kFloat64, torch_kCPU)
  ! Load model and Infer meridional
  call torch_module_forward(model, model_input_arr, n_inputs, gwfcng_y_tensor)


  ! Convert back into fortran types, reshape, and assign to gwfcng


  ! Cleanup
  call torch_tensor_delete(model_input_arr(1))
  call torch_tensor_delete(model_input_arr(2))
  call torch_tensor_delete(model_input_arr(3))
  !call torch_tensor_delete(model_input_arr)
  call torch_tensor_delete(gwfcng_x_tensor)
  call torch_tensor_delete(gwfcng_y_tensor)
  deallocate( uuu_flattened )
  deallocate( vvv_flattened )
  deallocate( uuu_reshaped )
  deallocate( vvv_reshaped )
  deallocate( lat_reshaped )
  deallocate( psfc_reshaped )


end subroutine cg_drag_ML


!####################################################################

end module cg_drag_ML_mod