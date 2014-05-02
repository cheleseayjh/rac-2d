module disk

use data_struct
use grid
use chemistry
use heating_cooling
use montecarlo
use load_Draine_dusts
use data_dump
use vertical
use my_timer


implicit none

type :: type_disk_basic_params
  double precision star_mass_in_Msun, star_radius_in_Rsun, star_temperature
  double precision :: T_Xray=1D7, E0_Xray=0.1D0, E1_Xray=10D0, lumi_Xray=1D30
  double precision :: starpos_r = 0D0, starpos_z = 0D0
  !
  double precision disk_mass_in_Msun
  !
  integer :: ngascompo=1, ndustcompo=1
  !type(type_Andrews_disk), dimension(MaxNumOfGasComponents) :: andrews_gas
  type(type_Andrews_disk) :: andrews_gas
  type(type_a_dust_component), dimension(MaxNumOfDustComponents) :: dustcompo
  !
  logical :: use_fixed_alpha_visc=.true.
  logical :: allow_gas_dust_en_exch=.false.
  double precision :: base_alpha = 0.01D0
  !
  logical :: waterShieldWithRadTran = .true.
  logical :: Tdust_iter_tandem = .false.
end type type_disk_basic_params


type :: type_disk_iter_params
  integer :: n_iter=128, n_iter_used = 0
  integer :: nlocal_iter = 2
  !
  double precision :: rtol_T = 0.1D0,    atol_T = 2D0
  double precision :: rtol_abun = 0.2D0, atol_abun = 1D-12
  !
  double precision :: Tgas_crazy = 3D4
  double precision :: n_gas_thrsh_noTEvol = 1D15
  double precision :: minimum_Tdust = 5D0
  !
  logical flag_converged
  integer n_cell_converged
  real converged_cell_percentage_stop
  !
  integer :: do_vertical_every = 7
  logical :: do_vertical_struct = .false.
  logical :: redo_montecarlo = .true.
  logical :: flag_save_rates = .false.
  !
  integer :: nSpecies_check_refine = 0
  integer :: ncell_refine = 0, count_refine = 0
  integer :: nMax_refine = 2
  double precision :: threshold_ratio_refine = 10D0
  character(len=128) filename_list_check_refine
  !
  character(len=128) iter_files_dir
  character(len=256) filename_exe
  logical            :: backup_src = .true.
  character(len=512) :: backup_src_cmd = &
    'find *.f90 *.f *.py makefile | cpio -pdm --insecure '
  !
  logical :: do_line_transfer=.false., do_continuum_transfer=.false.
  !
  character(len=128) :: dump_common_dir=''
  character(len=32) :: dump_sub_dir_in='', dump_sub_dir_out=''
  character(len=64) :: dump_filename_optical='', dump_filename_chemical='', &
                       dump_filename_physical='', dump_filename_physical_aux=''
  logical :: use_backup_optical_data  = .false.
  logical :: use_backup_chemical_data = .false.
  !
end type type_disk_iter_params


type :: type_ana_params
  logical :: do_analyse = .false.
  integer ana_i_incr
  character(len=128) analyse_points_inp_dir, analyse_out_dir
  character(len=128) file_list_analyse_points, file_list_analyse_species, &
                     file_analyse_res_ele, file_analyse_res_contri
  type(type_cell_rz_phy_basic) chempar
end type type_ana_params


type :: type_disk_iter_storage
  double precision, dimension(:), allocatable :: T_s
  double precision, dimension(:,:), allocatable :: abundances
end type type_disk_iter_storage


type :: type_book_keeping
  integer fU
  character(len=128) dir, filename_log
end type type_book_keeping


! For logging
type(type_book_keeping) a_book_keeping


type(date_time), private :: a_date_time

! Basic config params of the disk model
type(type_disk_basic_params) a_disk

! Iteration params for the disk model
type(type_disk_iter_params) a_disk_iter_params

! Storage for the disk model
type(type_disk_iter_storage) a_iter_stor

! Initialization params for each cell, which are the same for all the cells.
type(type_cell_rz_phy_basic) cell_params_ini

! Params for doing analysis
type(type_ana_params) a_disk_ana_params

! Point (location) list and species list for analysis
type(type_simple_integer_list) :: ana_ptlist, ana_splist

! Index list of the cells that are being calculated
integer, dimension(:), allocatable :: calculating_cells
integer n_calculating_cells, n_calculating_cells_max

! Filename for saving the results for each iteration; the name will be changed
! for different iterations.
character(len=128) :: filename_save_results
integer fU_save_results

! Perez-Becker 2011
double precision, parameter, private :: beta_ion_neutral_colli = 2D-9

! Index of species that are to be used for check whether cell refinement is
! needed.
integer, dimension(:), allocatable, private :: idx_Species_check_refine
double precision, dimension(:), allocatable, private :: &
    thr_Species_check_refine

! For displaying some text to the screen
character(len=256) str_disp

character(len=256), private :: dump_dir_in, dump_dir_out

! Field length for certain output
integer, parameter :: len_item=14

! Namelists for reading config params
namelist /disk_configure/ &
  a_disk

namelist /cell_configure/ &
  cell_params_ini

namelist /iteration_configure/ &
  a_disk_iter_params

namelist /analyse_configure/ &
  a_disk_ana_params


contains


subroutine montecarlo_prep
  integer i, i1
  double precision lam_max
  type(type_stellar_params) star_tmp
  double precision, parameter :: T_Lya=1000D0, lam_max_0=1D8
  integer, parameter :: n_interval_star=2000, n_interval_Xray=200
  !
  write(*, '(A/)') 'Preparing for the Monte Carlo.'
  !
  mc_conf%starpos_r = a_disk%starpos_r
  mc_conf%starpos_z = a_disk%starpos_z
  !
  if (mc_conf%ph_init_symmetric) then
    mc_conf%maxw = get_surf_max_angle(a_disk%starpos_r, a_disk%starpos_z)
    mc_conf%minw = -mc_conf%maxw
  else
    mc_conf%maxw = get_surf_max_angle(a_disk%starpos_r, a_disk%starpos_z)
    mc_conf%minw = get_bott_min_angle(a_disk%starpos_r, a_disk%starpos_z)
  end if
  !
  write(*,'(A, 2ES12.4)') 'Star location r,z = ', &
        mc_conf%starpos_r, mc_conf%starpos_z
  write(*,'(A, 2ES12.4/)') 'minw,maxw = ', mc_conf%minw, mc_conf%maxw
  !
  dust_0 = dusts%list(1)
  !
  call load_H2O_ab_crosssection( &
    combine_dir_filename(mc_conf%mc_dir_in, mc_conf%fname_water), &
    water_0)
  !
  if (.not. a_disk%waterShieldWithRadTran) then
    water_0%ab = 0D0
    water_0%sc = 0D0
    water_0%g  = 0D0
  end if
  !
  call make_H_Lya(T_Lya, HI_0)
  !
  ! Let the dust and H2O, H data share the same wavelength axis
  call align_optical_data
  !
  ! Create the lookup table for finding temperature and new wavelength during
  ! the Monte Carlo
  call make_luts
  !
  call openFileSequentialWrite(i1, &
       combine_dir_filename(a_book_keeping%dir, 'optical_parameters.dat'), &
       999, getu=1)
  do i=1, HI_0%n
    write(i1, '(I8, 13ES20.10E3)') &
        i, HI_0%lam(i), &
        HI_0%ab(i),          HI_0%sc(i),          HI_0%g(i), &
        water_0%ab(i),       water_0%sc(i),       water_0%g(i), &
        dusts%list(1)%ab(i), dusts%list(1)%sc(i), dusts%list(1)%g(i), &
        dusts%list(2)%ab(i), dusts%list(2)%sc(i), dusts%list(2)%g(i)
  end do
  close(i1)
  !
  ! Prepare for the stellar spectrum
  write(*, '(A)') 'Preparing for the stellar spectrum.'
  !
  lam_max = min(lam_max_0, dust_0%lam(dust_0%n)) ! in angstrom
  !
  ! Black body
  call make_stellar_spectrum(dust_0%lam(1), &
    lam_max, n_interval_star, a_star)
  call openFileSequentialWrite(i1, &
       combine_dir_filename(a_book_keeping%dir, 'stellar_spectrum_blackbody.dat'), &
       99, getu=1)
  do i=1, a_star%n
    write(i1, '(I8, 2ES20.10E3)') i, a_star%lam(i), a_star%vals(i)
  end do
  close(i1)
  !
  ! Thermal X-ray
  star_tmp%T_Xray = a_star%T_Xray
  star_tmp%lumi_Xray = a_star%lumi_Xray
  star_tmp%E0_Xray = a_star%E0_Xray
  star_tmp%E1_Xray = max(a_star%E1_Xray, &  ! The 1.01D0 here is for a stupid reason.
    phy_hPlanck_CGS*phy_SpeedOfLight_CGS/(a_star%lam(1)*1D-8)/phy_eV2erg/1D3*1.01D0)
  !
  call make_stellar_spectrum_Xray(n_interval_Xray, star_tmp)
  call openFileSequentialWrite(i1, &
       combine_dir_filename(a_book_keeping%dir, 'stellar_spectrum_Xray.dat'), &
       99, getu=1)
  do i=1, star_tmp%n
    write(i1, '(I8, 2ES20.10E3)') i, star_tmp%lam(i), star_tmp%vals(i)
  end do
  close(i1)
  !
  call merge_stellar_spectrum(star_tmp, a_star)
  !
  ! From observation
  if (.not. mc_conf%use_blackbody_star) then
    call load_stellar_spectrum( &
      trim(combine_dir_filename(mc_conf%mc_dir_in, mc_conf%fname_star)), &
      star_tmp)
    !
    call openFileSequentialWrite(i1, &
         combine_dir_filename(a_book_keeping%dir, 'stellar_spectrum_fromfile.dat'), &
         99, getu=1)
    do i=1, star_tmp%n
      write(i1, '(I8, 2ES20.10E3)') i, star_tmp%lam(i), star_tmp%vals(i)
    end do
    close(i1)
    !
    call merge_stellar_spectrum(star_tmp, a_star)
  end if
  !
  call openFileSequentialWrite(i1, &
       combine_dir_filename(a_book_keeping%dir, 'stellar_spectrum_merged.dat'), &
       99, getu=1)
  do i=1, a_star%n
    write(i1, '(I8, 2ES20.10E3)') i, a_star%lam(i), a_star%vals(i)
  end do
  close(i1)
  !
  a_star%lumi = get_stellar_luminosity(a_star)
  a_star%lumi_UV = get_stellar_luminosity(a_star, lam_range_UV(1), &
    lam_range_UV(2))
  a_star%lumi_Lya = get_stellar_luminosity(a_star, lam_range_LyA(1), &
    lam_range_LyA(2))
  a_star%lumi_Vis = get_stellar_luminosity(a_star, lam_range_Vis(1), &
    lam_range_Vis(2))
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar total luminosity: ', a_star%lumi, ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar X-ray luminosity: ', &
    get_stellar_luminosity(a_star, lam_range_Xray(1), lam_range_Xray(2)), &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar X-ray luminosity (given): ', a_star%lumi_Xray, &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar UV luminosity: ', a_star%lumi_UV, ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') & ! Schindhelm 2012
    'Stellar UV luminosity (1160 to 1695): ', &
    get_stellar_luminosity(a_star, 1160D0, 1695D0), &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar Lyman alpha luminosity: ', a_star%lumi_Lya, &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar visual luminosity: ', a_star%lumi_Vis, &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar NIR luminosity: ', &
    get_stellar_luminosity(a_star, lam_range_NIR(1), lam_range_NIR(2)), &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar MIR luminosity: ', &
    get_stellar_luminosity(a_star, lam_range_MIR(1), lam_range_MIR(2)), &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  write(str_disp, '(A, ES16.6, A)') &
    'Stellar FIR luminosity: ', &
    get_stellar_luminosity(a_star, lam_range_FIR(1), lam_range_FIR(2)), &
    ' erg s-1.'
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  allocate(a_star%vals0(a_star%n))
  a_star%vals0 = a_star%vals
  a_star%lumi0 = a_star%lumi
  a_star%lumi_UV0 =  a_star%lumi_UV
  !
  ! The lumi and vals of a_star will be changed here.
  call get_mc_stellar_par(a_star, mc_conf)
  !
  ! Global optical property collection
  call make_global_coll
  !
  p4lam%n = luts%list(1)%m
  allocate(p4lam%pvals(0:p4lam%n))
  !
  if (mc_conf%collect_photon) then
    call set_up_collector(collector, &
      minlam=mc_conf%collect_lam_min, maxlam=mc_conf%collect_lam_max, &
      dmu=mc_conf%collect_dmu, nmu=mc_conf%collect_nmu, nr=mc_conf%collect_nr, &
      nphi=mc_conf%collect_nphi, &
      ang_mins=mc_conf%collect_ang_mins, ang_maxs=mc_conf%collect_ang_maxs)
  end if
  !
end subroutine montecarlo_prep



subroutine merge_stellar_spectrum(s1, s2)
  type(type_stellar_params), intent(in) :: s1
  type(type_stellar_params), intent(inout) :: s2
  double precision, dimension(:), allocatable :: v1, v2
  integer n
  n = s1%n + s2%n
  allocate(v1(n), v2(n))
  call merge_vec(s1%n, s1%lam, s2%n, s2%lam, n, v1)
  call transfer_value(s2%n, s2%lam, s2%vals, n, v1, v2)
  call transfer_value(s1%n, s1%lam, s1%vals, n, v1, v2, keep=.true.)
  deallocate(s2%lam, s2%vals)
  allocate(s2%lam(n), s2%vals(n))
  s2%n = n
  s2%lam = v1
  s2%vals = v2
end subroutine merge_stellar_spectrum



subroutine make_dusts_data
  integer i, j, itype, nradius, nradius_prev, nlam
  double precision rmin, rmax, ind, swei, m
  double precision, dimension(:), allocatable :: t1, t2
  !
  dusts%n = a_disk%ndustcompo
  allocate(dusts%list(dusts%n))
  nradius = 0
  !
  do i=1, dusts%n
    !
    call calc_dust_MRN_par(a_disk%dustcompo(i)%mrn)
    !
    rmin  = a_disk%dustcompo(i)%mrn%rmin
    rmax  = a_disk%dustcompo(i)%mrn%rmax
    ind   = a_disk%dustcompo(i)%mrn%n
    itype = a_disk%dustcompo(i)%itype
    !
    rmax = max(rmax, rmin*1.0001D0)
    !
    nradius_prev = nradius
    nradius = dustmix_data%list(itype)%nradius
    nlam = dustmix_data%list(itype)%nlam
    !
    if (i .gt. 1) then
      if (dusts%list(i-1)%n .ne. nlam) then
        write(*,'(A)') 'In make_dusts_data:'
        write(*,'(A)') 'Arrays for different dust types not'// &
                       'having the same dimension!'
        stop
      end if
      if (nradius .ne. nradius_prev) then
        write(*, '(A)') 'In make_dusts_data:'
        write(*, '(A)') 'Inconsistent radius array size!'
        stop
      end if
    end if
    !
    dusts%list(i)%n = nlam
    !
    allocate(dusts%list(i)%lam(nlam), &
             dusts%list(i)%ab(nlam), &
             dusts%list(i)%sc(nlam), &
             dusts%list(i)%g(nlam))
    !
    if (.not. allocated(t1)) then
      allocate(t1(nradius), t2(nradius))
    end if
    !
    do j=1, nlam
      !
      dusts%list(i)%lam(j) = &
        dustmix_data%list(itype)%w(j) / phy_Angstrom2micron
      !
      t1 = exp(-ind*log(dustmix_data%list(itype)%r)) ! = r**(-ind)
      !
      swei = discrete_integral( &
        nradius, dustmix_data%list(itype)%r, t1, rmin, rmax)
      !
      t2 = t1 * dustmix_data%list(itype)%ab(j, :)
      dusts%list(i)%ab(j) = discrete_integral( &
        nradius, dustmix_data%list(itype)%r, t2, rmin, rmax)
      !
      t2 = t1 * dustmix_data%list(itype)%sc(j, :)
      dusts%list(i)%sc(j) = discrete_integral( &
        nradius, dustmix_data%list(itype)%r, t2, rmin, rmax)
      !
      t2 = t1 * dustmix_data%list(itype)%g(j, :)
      dusts%list(i)%g(j) = discrete_integral( &
        nradius, dustmix_data%list(itype)%r, t2, rmin, rmax)
      !
      m = 4D0*phy_Pi/3D0 * a_disk%dustcompo(i)%mrn%r3av * &
          phy_micron2cm**3 * dustmix_info%mix(itype)%rho
      a_disk%dustcompo(i)%pmass_CGS = m ! dust particle mass in gram
      !
      ! Now the unit of ab and sc become cm2 g-1.
      dusts%list(i)%ab(j) = dusts%list(i)%ab(j) / swei * phy_micron2cm**2 / m
      dusts%list(i)%sc(j) = dusts%list(i)%sc(j) / swei * phy_micron2cm**2 / m
      dusts%list(i)%g(j) = dusts%list(i)%g(j) / swei
      !write(*, '(2I4, 10ES12.4)') i, j, dusts%list(i)%lam(j), &
      !  dusts%list(i)%ab(j), dusts%list(i)%sc(j), dusts%list(i)%g(j), &
      !  m, a_disk%dustcompo(i)%mrn%r3av, swei, rmin, rmax, maxval(dustmix_data%list(itype)%g(j, :))
    end do
  end do
end subroutine make_dusts_data




subroutine do_optical_stuff(iiter)
  integer, intent(in) :: iiter
  !
  write(*, '(A)') 'Preparing optical data for all the cells.'
  call montecarlo_reset_cells
  !
  if ((.not. a_disk_iter_params%use_backup_optical_data) .or. &
      (iiter .gt. 1)) then
    write(str_disp, '("! ", A)') "Monte Carlo begins."
    call display_string_both(str_disp, a_book_keeping%fU)
    write(str_disp, '(A)') '! Current time: ' // &
        trim(a_date_time%date_time_str())
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    call montecarlo_do(mc_conf, root)
    !
    ! Retrieve physical parameters from the monte carlo results
    call post_montecarlo
    !
    write(str_disp, '("! ", A, I16)') 'Number of photon packets used:', mc_conf%icount
    call display_string_both(str_disp, a_book_keeping%fU)
    write(str_disp, '("! ", A)') "Monte Carlo finished."
    call display_string_both(str_disp, a_book_keeping%fU)
    write(str_disp, '(A)') '! Current time: ' // &
        trim(a_date_time%date_time_str())
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    write(str_disp, '(A, I6)') '! iiter = ', iiter
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    write(str_disp, '("! ", A)') "Dumping optical data..."
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    call back_cells_optical_data(dump_dir_out, iiter=iiter, dump=.true.)
    !
    write(str_disp, '("! ", A)') "Dumping preliminary physical data..."
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    call back_cells_physical_data(dump_dir_out, iiter=iiter, dump=.true., preliminary=.true.)
    !
    write(str_disp, '("! ", 2A)') 'Data dumped in ', trim(dump_dir_out)
    call display_string_both(str_disp, a_book_keeping%fU)
  else
    write(str_disp, '("! ", A)') "Loading backuped optical data..."
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    call back_cells_optical_data(dump_dir_in, &
           fname=a_disk_iter_params%dump_filename_optical, dump=.false.)
    !
    if ((len_trim(a_disk_iter_params%dump_filename_physical) .gt. 0) .and. &
        (.not. a_disk_iter_params%use_backup_chemical_data)) then
      ! When intending to use previous optical data for further chemical
      ! calculation, some associated physical data must also be loaded for the
      ! chemical part to run properly.
      call back_cells_physical_data(dump_dir_in, &
           fname=a_disk_iter_params%dump_filename_physical, dump=.false.)
    end if
    !
  end if
end subroutine do_optical_stuff



subroutine do_chemical_stuff(iiter)
  integer, intent(in) :: iiter
  integer i, i0, i_count, l_count
  !
  if ((.not. a_disk_iter_params%use_backup_chemical_data) .or. &
      (iiter .gt. 1)) then
    ! Start from the inner edge layer.
    n_calculating_cells = columns_idx(1)%nlen
    calculating_cells(1:n_calculating_cells) = columns_idx(1)%vals
    !
    i_count = 0 ! Counter for cells
    l_count = 0 ! Counter for layers
    !
    do
      l_count = l_count + 1
      !
      do i=1, n_calculating_cells
        i_count = i_count + 1
        i0 = calculating_cells(i)
        !
        write(*, '(3(A, I5, A, I5, ",", 2X), (A, I4, ","), 2X, A, 4F8.3)') &
          "Iter:", a_disk_iter_params%n_iter_used, "/", &
          a_disk_iter_params%n_iter, &
          "Cell:", i_count, '/', leaves%nlen, &
          "cell:", i, '/', n_calculating_cells, &
          "Layer:", l_count, &
          'rz:', &
          leaves%list(i0)%p%par%rmin, &
          leaves%list(i0)%p%par%rmax, &
          leaves%list(i0)%p%par%zmin, &
          leaves%list(i0)%p%par%zmax
        write(*, '(2(A, ES10.3, 2X), 2X, 2A, 2X, 2A)') &
          'n_gas: ', leaves%list(i0)%p%par%n_gas, &
          'Tdust: ', leaves%list(i0)%p%par%Tdust, &
          'exe: ', trim(a_disk_iter_params%filename_exe), &
          'dir: ', trim(a_disk_iter_params%iter_files_dir)
        !
        call calc_this_cell(i0)
        !
        call check_convergency_cell(i0)
        !
        write(*, '(12X, 10A10)') chem_idx_some_spe%names(1:10)
        write(*, '(A, 2X, 10ES10.3, L3/)') 'Abundances:',  &
          leaves%list(i0)%p%abundances(chem_idx_some_spe%idx(1:10)), &
          leaves%list(i0)%p%converged
        !
        a_iter_stor%T_s(i0) = leaves%list(i0)%p%par%Tgas
        !
        a_iter_stor%abundances(:, i0) = &
          leaves%list(i0)%p%abundances(chem_idx_some_spe%idx)
        !
        call disk_save_results_write(fU_save_results, leaves%list(i0)%p)
        flush(fU_save_results)
      end do
      !
      !call update_calculating_cells
      if (l_count .ge. bott_cells%nlen) then
        exit
      end if
      n_calculating_cells = columns_idx(l_count+1)%nlen
      calculating_cells(1:n_calculating_cells) = columns_idx(l_count+1)%vals
      !
      if (n_calculating_cells .le. 0) then
        exit
      end if
    end do
    !
    write(str_disp, '(A)') '! Current time: ' // &
        trim(a_date_time%date_time_str())
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    write(str_disp, '(A, I6)') '! iiter = ', iiter
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    write(str_disp, '("! ", A)') "Dumping chemical data..."
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    call back_cells_chemical_data(dump_dir_out, iiter=iiter, dump=.true.)
    !
    write(str_disp, '("! ", 2A)') 'Data dumped in ', trim(dump_dir_out)
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    write(str_disp, '("! ", A)') "Dumping physical data..."
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    call back_cells_physical_data(dump_dir_out, iiter=iiter, dump=.true.)
    !
    call back_cells_physical_data_aux(dump_dir_out, iiter=iiter, dump=.true.)
    !
    write(str_disp, '("! ", 2A)') 'Data dumped in ', trim(dump_dir_out)
    call display_string_both(str_disp, a_book_keeping%fU)
  else
    write(str_disp, '("! ", A)') &
        "Loading backuped chemical and physical data..."
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    call back_cells_chemical_data(dump_dir_in, &
           fname=a_disk_iter_params%dump_filename_chemical, dump=.false.)
    !
    call back_cells_physical_data(dump_dir_in, &
           fname=a_disk_iter_params%dump_filename_physical, dump=.false.)
    !
    call back_cells_physical_data_aux(dump_dir_in, &
           fname=a_disk_iter_params%dump_filename_physical_aux, dump=.false.)
    !
    call check_consistency_of_loaded_data_phy
  end if
end subroutine do_chemical_stuff



subroutine disk_iteration
  integer i, i0, i_count, l_count, ii
  !
  dump_dir_in = combine_dir_filename(a_disk_iter_params%dump_common_dir, &
                                  a_disk_iter_params%dump_sub_dir_in)
  dump_dir_out = combine_dir_filename(a_disk_iter_params%dump_common_dir, &
                                  a_disk_iter_params%dump_sub_dir_out)
  call my_mkdir(dump_dir_out)
  !
  call disk_iteration_prepare
  !
  call montecarlo_prep
  !
  if (a_disk_iter_params%do_line_transfer) then
  end if
  !
  call save_post_config_params
  !
  ! Now start the major big loop.
  !
  a_disk_iter_params%count_refine = 0
  !
  write(str_disp, '("! ", A)') "Iteration begins."
  call display_string_both(str_disp, a_book_keeping%fU)
  write(str_disp, '(A)') '! Current time: ' // &
    trim(a_date_time%date_time_str())
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  do ii = 1, a_disk_iter_params%n_iter
    !
    a_disk_iter_params%n_iter_used = ii
    !
    call do_optical_stuff(ii)
    !
    if (mc_conf%collect_photon) then
      ! Save the spectrum generated from the collected photons that have escaped.
      call save_collected_photons_iter(ii)
    end if
    !
    ! Write header to the file
    call disk_save_results_pre
    !
    call do_chemical_stuff(ii)
    !
    write(str_disp, '("! ", A, I4, A)') "Iteration ", ii, " finished."
    call display_string_both(str_disp, a_book_keeping%fU)
    write(str_disp, '(A)') '! Current time: ' // &
        trim(a_date_time%date_time_str())
    call display_string_both(str_disp, a_book_keeping%fU)
    !
    ! At this point all the layers have been walked through,
    ! so check whether the global iteration has converged.
    call check_convergency_whole_disk
    !
    write(fU_save_results, '(A, L6)') &
      '! flag_converged = ', a_disk_iter_params%flag_converged
    write(fU_save_results, '(A)') &
      '! Finish saving ' // trim(filename_save_results)
    write(fU_save_results, '(A)') '! at ' // trim(a_date_time%date_time_str())
    flush(fU_save_results)
    close(fU_save_results)
    !
    if (a_disk_iter_params%flag_converged) then
      ! Converged.  Finish iteration.
      exit
    !
    else if (a_disk_iter_params%redo_montecarlo) then
      if (a_disk_iter_params%do_vertical_struct) then
        if (mod(ii, a_disk_iter_params%do_vertical_every) .eq. &
            (a_disk_iter_params%do_vertical_every-1)) then
          ! Adjust the vertical structure
          !
          write(str_disp, '(A)') '! Adjusting the vertical structure.'
          call display_string_both(str_disp, a_book_keeping%fU)
          !
          call vertical_pressure_gravity_balance
          !
          mc_conf%maxw = get_surf_max_angle()
          if (mc_conf%ph_init_symmetric) then
            mc_conf%minw = -mc_conf%maxw
          end if
          call get_mc_stellar_par(a_star, mc_conf)
          !
          write(str_disp, '(A, 2F9.4)') 'New minw,maxw: ', mc_conf%minw, mc_conf%maxw
          call display_string_both(str_disp, a_book_keeping%fU)
          write(*, *)
          !
          write(str_disp, '(A)') '! Current time: ' // &
                                 trim(a_date_time%date_time_str())
          call display_string_both(str_disp, a_book_keeping%fU)
          !
        end if
      end if
      cycle
    !
    else if (a_disk_iter_params%count_refine .gt. &
             a_disk_iter_params%nMax_refine) then
      write(str_disp, '(A, I4, " > ", I4)') &
        '! Will not refine any more. count_refine: ', &
        a_disk_iter_params%count_refine, a_disk_iter_params%nMax_refine
      call display_string_both(str_disp, a_book_keeping%fU)
      exit
    !
    else
      write(*, '(/A)') 'Doing refinements where necessary.'
      !
      call do_refine
      !
      if (a_disk_iter_params%ncell_refine .ge. 1) then
        !
        a_disk_iter_params%count_refine = a_disk_iter_params%count_refine + 1
        a_disk_iter_params%flag_converged = .false.
        !
        write(*, '(I5, " out of ", I5, " cells are refined.", /)') &
          a_disk_iter_params%ncell_refine, leaves%nlen
        !
        call remake_index
        !
        call load_ana_points_list ! Reload, actually
        !
        if (allocated(a_iter_stor%T_s)) then
          deallocate(a_iter_stor%T_s, a_iter_stor%abundances)
        end if
        allocate(a_iter_stor%T_s(leaves%nlen), &
                 a_iter_stor%abundances(chem_idx_some_spe%nItem, &
                                                leaves%nlen))
        do i=1, leaves%nlen
          a_iter_stor%T_s(i) = leaves%list(i)%p%par%Tgas
          a_iter_stor%abundances(:,i) = &
            leaves%list(i)%p%abundances(chem_idx_some_spe%idx)
        end do
        !
        if (allocated(calculating_cells)) then
          deallocate(calculating_cells)
        end if
        n_calculating_cells_max = leaves%nlen
        allocate(calculating_cells(n_calculating_cells_max))
        !
        write(str_disp, '("!", A, 2X, I5)') 'New number of cells (leaf):', leaves%nlen
        call display_string_both(str_disp, a_book_keeping%fU)
        write(str_disp, '("!", A, 2X, I5)') 'New number of cells (total):', root%nOffspring
        call display_string_both(str_disp, a_book_keeping%fU)
      else
        write(str_disp, '("! ", A)') "No further refinement needed."
        call display_string_both(str_disp, a_book_keeping%fU)
      end if
    end if
  end do
  !
  if (a_disk_iter_params%flag_converged) then
    write(*, '(A/)') "Iteration has converged!"
  else
    write(*, '(A/)') "Iteration hasn't converged. :("
  end if
  !
  if (FileUnitOpened(a_book_keeping%fU)) then
    write(a_book_keeping%fU, nml=iteration_configure)
  end if
  write(str_disp, '("!Final number of cells =", I4)') leaves%nlen
  call display_string_both(str_disp, a_book_keeping%fU)
  !
end subroutine disk_iteration




subroutine post_montecarlo
  integer i, j
  integer i1, i2
  double precision vx, vy, vz
  double precision RR, tmp, tmp0, tmp1
  !
  do i=1, leaves%nlen
    associate(c => leaves%list(i)%p)
      tmp = 0D0
      tmp0 = 0D0
      do j=1, dusts%n
        if (c%par%n_dusts(j) .le. 1D-100) then
          c%par%Tdusts(j) = 0D0
          cycle
        end if
        !
        c%par%Tdusts(j) = get_Tdust_from_LUT( &
            (c%par%en_gains(j) + c%par%en_exchange(j)) &
            / (4*phy_Pi*c%par%mdusts_cell(j)), &
            luts%list(j), i1)
        !
        if (c%par%Tdusts(j) .le. 0D0) then
          write(*, '(A, 4ES16.6, I4, 2ES16.6)') 'Tdusts(j)=0: ', &
            c%xmin, c%xmax, c%ymin, c%ymax, j, c%par%en_gains(j), c%par%en_exchange(j)
        end if
        !
        tmp1 = c%par%n_dusts(j) * a_disk%dustcompo(j)%mrn%r2av
        tmp0 = tmp0 + c%par%Tdusts(j) * tmp1
        tmp = tmp + tmp1
        !
      end do
      !else
      !end if
      c%par%Tdust = max(tmp0 / tmp, a_disk_iter_params%minimum_Tdust)
      !
      c%par%en_gain_tot = sum(c%par%en_gains)
      c%par%en_gain_abso_tot = sum(c%par%en_gains_abso)
      !
      ! Flux of each cell as a function of wavelength
      c%optical%flux = c%optical%flux * (phy_AU2cm / c%par%volume)
      call fill_blank(dust_0%lam, c%optical%flux, c%optical%phc, &
                      c%optical%nlam, 1, 3+c%optical%nlam/100)
      !
      ! Get some properties of the radiation field
      ! Only use the wavelength vector of dust_0
      !
      ! Total
      i1 = 1
      i2 = dust_0%n
      c%par%flux_tot = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_tot)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_tot)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_tot)
      c%par%dir_tot_r = vx
      c%par%dir_tot_z = vz
      c%par%aniso_tot = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! X-ray
      i1 = max(1, get_idx_for_kappa(lam_range_Xray(1), dust_0))
      i2 = min(dust_0%n, get_idx_for_kappa(lam_range_Xray(2), dust_0))
      c%par%flux_Xray = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Xray)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Xray)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Xray)
      c%par%dir_Xray_r = vx
      c%par%dir_Xray_z = vz
      c%par%aniso_Xray = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! UV
      i1 = max(1, get_idx_for_kappa(lam_range_UV(1), dust_0))
      i2 = min(dust_0%n, get_idx_for_kappa(lam_range_UV(2), dust_0))
      c%par%flux_UV = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_UV)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_UV)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_UV)
      c%par%dir_UV_r = vx
      c%par%dir_UV_z = vz
      c%par%aniso_UV = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! Lya
      i1 = max(1, get_idx_for_kappa(lam_range_LyA(1), dust_0))
      i2 = min(dust_0%n, get_idx_for_kappa(lam_range_LyA(2), dust_0))
      c%par%flux_Lya = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Lya)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Lya)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Lya)
      c%par%dir_Lya_r = vx
      c%par%dir_Lya_z = vz
      c%par%aniso_Lya = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! Visual
      i1 = max(1, get_idx_for_kappa(lam_range_Vis(1), dust_0))
      i2 = min(dust_0%n, get_idx_for_kappa(lam_range_Vis(2), dust_0))
      c%par%flux_Vis = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Vis)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Vis)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_Vis)
      c%par%dir_Vis_r = vx
      c%par%dir_Vis_z = vz
      c%par%aniso_Vis = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! NIR
      i1 = max(1, get_idx_for_kappa(lam_range_NIR(1), dust_0))
      i2 = min(dust_0%n, get_idx_for_kappa(lam_range_NIR(2), dust_0))
      c%par%flux_NIR = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_NIR)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_NIR)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_NIR)
      c%par%dir_NIR_r = vx
      c%par%dir_NIR_z = vz
      c%par%aniso_NIR = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! MIR
      i1 = max(1, get_idx_for_kappa(lam_range_MIR(1), dust_0))
      i2 = min(dust_0%n, get_idx_for_kappa(lam_range_MIR(2), dust_0))
      c%par%flux_MIR = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_MIR)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_MIR)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_MIR)
      c%par%dir_MIR_r = vx
      c%par%dir_MIR_z = vz
      c%par%aniso_MIR = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! FIR
      i1 = max(1, get_idx_for_kappa(lam_range_FIR(1), dust_0))
      i2 = min(dust_0%n, get_idx_for_kappa(lam_range_FIR(2), dust_0))
      c%par%flux_FIR = sum(c%optical%flux(i1:i2))
      vx = sum(c%optical%dir_wei(i1:i2)%u) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_FIR)
      vy = sum(c%optical%dir_wei(i1:i2)%v) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_FIR)
      vz = sum(c%optical%dir_wei(i1:i2)%w) / c%par%volume * phy_AU2cm / (1D-100 + c%par%flux_FIR)
      c%par%dir_FIR_r = vx
      c%par%dir_FIR_z = vz
      c%par%aniso_FIR = sqrt(vx**2 + vy**2 + vz**2)
      !
      ! Local number flux of Lyman alpha
      c%par%phflux_Lya = c%par%flux_Lya / phy_LyAlpha_energy_CGS
      c%par%G0_Lya_atten = c%par%flux_Lya / phy_Habing_energy_flux_CGS
      !
      ! Calculate the total column density to the star and to the ISM
      call calc_Ncol_to_ISM(leaves%list(i)%p)
      call calc_Ncol_to_Star(leaves%list(i)%p)
      !
      RR = (c%par%rcen**2 + c%par%zcen**2) * phy_AU2cm**2
      c%par%flux_UV_star_unatten = a_star%lumi_UV0 / (4D0*phy_Pi*RR)
      c%par%flux_Lya_star_unatten = a_star%lumi_Lya / (4D0*phy_Pi*RR)
      c%par%flux_Vis_star_unatten = a_star%lumi_Vis / (4D0*phy_Pi*RR)
      !
      ! Calculate the G0 factors
      ! The G0 is the unattenuated one, so a further
      ! exp(-k*Av) should be applied.
      c%par%G0_UV_toStar = c%par%flux_UV_star_unatten / phy_Habing_energy_flux_CGS
      c%par%G0_UV_toISM  = c%par%UV_G0_factor_background
      !
      c%par%Av_toStar = max(0D0, &
        -1.086D0 * log(c%par%flux_UV / c%par%flux_UV_star_unatten) / phy_UVext2Av)
      ! The Av to ISM is a simple scaling of the dust column density
      ! The factor 2 is to account for the scattering.
      c%par%Av_toISM = 1.086D0 * (phy_Pi * c%par%GrainRadius_CGS**2 * 2D0) * &
                       calc_Ncol_from_cell_to_point(c, c%par%rcen, root%ymax*2D0, -5)
    end associate
  end do
end subroutine post_montecarlo


pure subroutine fill_blank(x, v, mask, n, nth, nrange)
  integer, intent(in) :: n, nth, nrange
  double precision, dimension(n), intent(in) :: x
  double precision, dimension(n), intent(inout) :: v
  integer, dimension(n), intent(in) :: mask
  integer i, j, jmin, jmax
  double precision s, smean
  do i=1, n
    if (mask(i) .lt. nth) then
      jmin = n
      jmax = 1
      do j=i-1, 1, -1
        if (mask(j) .ge. nth) then
          jmin = j
          exit
        end if
      end do
      do j=i+1, n
        if (mask(j) .ge. nth) then
          jmax = j
          exit
        end if
      end do
      jmin = min(jmin, max(1, i-nrange))
      jmax = max(jmax, min(n, i+nrange))
      s = 0D0
      do j=jmin, jmax-1
        s = s + v(j)
      end do
      smean = s / abs(x(jmax) - x(jmin))
      do j=jmin, jmax-1
        v(j) = smean * abs(x(j+1) - x(j))
      end do
    end if
  end do
end subroutine fill_blank



subroutine montecarlo_reset_cells
  integer i
  do i=1, leaves%nlen
    associate(c => leaves%list(i)%p)
      !
      c%par%Tdusts = 0D0
      !
      c%par%X_HI  = c%abundances(chem_idx_some_spe%i_HI)
      c%par%X_H2O = c%abundances(chem_idx_some_spe%i_H2O)
      !
      call calc_Ncol_to_ISM(leaves%list(i)%p)
      call calc_Ncol_to_Star(leaves%list(i)%p)
      !
      call allocate_local_optics(leaves%list(i)%p, &
                                 opmaterials%ntype, dust_0%n)
      call reset_local_optics(leaves%list(i)%p)
    end associate
  end do
  !
end subroutine montecarlo_reset_cells



subroutine disk_iteration_prepare
  integer i
  !
  ! The density structure is needed for making the grid.
  a_andrews_4ini = a_disk%andrews_gas
  a_andrews_4ini%particlemass = 1.4D0 * phy_mProton_CGS
  !
  a_star%mass      = a_disk%star_mass_in_Msun
  a_star%radius    = a_disk%star_radius_in_Rsun
  a_star%T         = a_disk%star_temperature
  !
  a_star%T_Xray    = a_disk%T_Xray
  a_star%E0_Xray   = a_disk%E0_Xray
  a_star%E1_Xray   = a_disk%E1_Xray
  a_star%lumi_Xray = a_disk%lumi_Xray
  !
  write(*, '(A/)') 'Making grid.'
  call make_grid
  !
  n_calculating_cells_max = leaves%nlen
  allocate(calculating_cells(n_calculating_cells_max))
  !
  write(*, '(A/)') 'Preparing dust data.'
  call prep_dust_data ! Load dust data, and create the mixtures
  !
  call make_dusts_data ! Prepare the dust optical data for use
  !
  ! Prepare the chemical stuff
  chemsol_params%fU_log = a_book_keeping%fU
  !
  write(*, '(A/)') 'Loading chemcial reactions.'
  call chem_read_reactions()
  call chem_load_reactions()
  call chem_parse_reactions()
  call chem_get_dupli_reactions()
  call chem_get_idx_for_special_species()
  call load_species_enthalpies
  call get_reaction_heat
  !
  call load_refine_check_species
  !
  call chem_make_sparse_structure
  call chem_prepare_solver_storage
  call chem_evol_solve_prepare_run_once
  !
  call chem_load_initial_abundances
  !
  write(str_disp, '("!", A, 2X, I5)') 'Number of cells (leaf):', leaves%nlen
  call display_string_both(str_disp, a_book_keeping%fU)
  write(str_disp, '("!", A, 2X, I5)') 'Number of cells (total):', root%nOffspring
  call display_string_both(str_disp, a_book_keeping%fU)
  write(str_disp, '("!", A, 2X, I5)') 'Number of reactions:', chem_net%nReactions
  call display_string_both(str_disp, a_book_keeping%fU)
  write(str_disp, '("!", A, 2X, I5)') 'Number of species ', chem_species%nSpecies
  call display_string_both(str_disp, a_book_keeping%fU)
  !
  !! Set the disk and cell parameters
  !write(*, '(A/)') 'Setting disk parameters.'
  !call disk_set_disk_params
  !
  write(*, '(A/)') 'Setting cell parameters.'
  call disk_set_gridcell_params
  call make_columns
  !
  if (.NOT. allocated(a_iter_stor%T_s)) then
    allocate(a_iter_stor%T_s(leaves%nlen), &
             a_iter_stor%abundances(chem_idx_some_spe%nItem, &
                                    leaves%nlen))
  end if
  !
  do i=1, leaves%nlen
    leaves%list(i)%p%abundances = chemsol_stor%y(1:chem_species%nSpecies)
    a_iter_stor%T_s(i) = leaves%list(i)%p%par%Tgas
    a_iter_stor%abundances(:, i) = chemsol_stor%y(chem_idx_some_spe%idx)
  end do
  !
  call disk_calc_disk_mass
  !
  write(*, '(A/)') 'Preparing for the heating cooling parameters.'
  !
  call heating_cooling_prepare
  if (a_disk%allow_gas_dust_en_exch) then
    heating_cooling_config%use_mygasgraincooling = .true.
  end if
  !
  if (a_disk_ana_params%do_analyse) then
    call load_ana_species_list
    call load_ana_points_list
    call get_species_produ_destr
    a_disk_ana_params%analyse_out_dir = &
      trim(combine_dir_filename(a_disk_iter_params%iter_files_dir, 'ana/'))
    if (.not. dir_exist(a_disk_ana_params%analyse_out_dir)) then
      call my_mkdir(a_disk_ana_params%analyse_out_dir)
    end if
  end if
  !
  mc_conf%mc_dir_out = trim( &
    combine_dir_filename( &
      a_disk_iter_params%iter_files_dir, &
      mc_conf%mc_dir_out))
  if (.not. dir_exist(mc_conf%mc_dir_out)) then
    call my_mkdir(mc_conf%mc_dir_out)
  end if
  !
end subroutine disk_iteration_prepare



subroutine calc_this_cell(id)
  integer, intent(in) :: id
  integer i, isav, j
  double precision tmp
  double precision, dimension(const_nElement) :: ele_bef, ele_aft
  !
  leaves%list(id)%p%iIter = a_disk_iter_params%n_iter_used
  !
  if (chemsol_params%flag_chem_evol_save) then
    chemsol_params%chem_evol_save_filename = &
      trim(combine_dir_filename( &
        a_disk_iter_params%iter_files_dir, 'chem_evol_tmp.dat'))
  end if
  !
  chem_params => leaves%list(id)%p%par
  hc_params => leaves%list(id)%p%par
  !
  ! Set the initial condition for chemical evolution
  call set_initial_condition_4solver(id, 1, leaves%list(id)%p%iIter)
  !
  do j=1, a_disk_iter_params%nlocal_iter
    !
    write(*, '("Local iter: ", I4, " of ", I4)') j, &
        a_disk_iter_params%nlocal_iter
    !
    if (j .gt. 1) then
      call set_initial_condition_4solver_continue(id)
      write(*, '(A, ES16.6)') 'Continue running from tout=', chemsol_params%t0
    end if
    !
    call chem_set_solver_flags_alt(j)
    !
    write(*, '(4X, A, F12.3/)') 'Tgas_old: ', leaves%list(id)%p%par%Tgas
    !
    call update_params_above_alt(id)
    !
    call chem_cal_rates
    !
    call set_heatingcooling_params_from_cell(id)
    !
    call get_elemental_abundance(chemsol_stor%y, chemsol_params%NEQ, ele_bef, const_nElement)
    !
    call chem_evol_solve
    !
    call get_elemental_abundance(chemsol_stor%y, chemsol_params%NEQ, ele_aft, const_nElement)
    !
    write(*, '(A)') 'Elemental abundances (before, after, diff):'
    do i=1, const_nElement
      tmp = (ele_aft(i) - ele_bef(i)) / (ele_bef(i) + ele_aft(i))
      if (abs(tmp) .ge. 1D-6) then
        write(*, '(4X, A8, 3ES16.6)') const_nameElements(i), &
          ele_bef(i), ele_aft(i), tmp
      end if
    end do
    !
    if ((j .gt. 1) .and. &
        (chemsol_stor%touts(chemsol_params%n_record_real) .le. &
         leaves%list(id)%p%par%t_final)) then
      write(str_disp, '(A)') 'Local iteration does not proceed!!!'
      call display_string_both(str_disp, a_book_keeping%fU)
      !
      write(str_disp, '(A, ES16.6)') 'Stop local iteration.  Tgas=', &
          chemsol_stor%y(chem_species%nSpecies+1)
      call display_string_both(str_disp, a_book_keeping%fU)
      exit
    end if
    !
    do isav=chemsol_params%n_record_real, 1, -1
      if ((.not. isnan(chemsol_stor%record(chem_species%nSpecies+1, isav))) .and. &
          (.not. isnan(chemsol_stor%record(chem_idx_some_spe%i_H2, isav)))) then
        exit
      end if
    end do
    isav = max(isav, 1)
    !
    leaves%list(id)%p%abundances = chemsol_stor%record(1:chem_species%nSpecies, isav)
    leaves%list(id)%p%par%Tgas = chemsol_stor%record(chem_species%nSpecies+1, isav)
    leaves%list(id)%p%quality = chemsol_params%quality
    leaves%list(id)%p%par%t_final = chemsol_stor%touts(isav)
    !
    if (isnan(leaves%list(id)%p%par%Tgas) .or. &
        (leaves%list(id)%p%par%Tgas .le. 0D0) .or. &
        (leaves%list(id)%p%par%Tgas .gt. a_disk_iter_params%Tgas_crazy)) then
      write(str_disp, '(A)') 'Tgas is crazy!'
      call display_string_both(str_disp, a_book_keeping%fU)
      write(str_disp, '(A, ES16.6)') 'Tgas=', leaves%list(id)%p%par%Tgas
      call display_string_both(str_disp, a_book_keeping%fU)
      !
      if (leaves%list(id)%p%par%Tgas .gt. a_disk_iter_params%Tgas_crazy) then
        leaves%list(id)%p%par%Tgas = a_disk_iter_params%Tgas_crazy
      else
        leaves%list(id)%p%par%Tgas = leaves%list(id)%p%par%Tdust
      end if
      !
      write(str_disp, '(A, ES16.6)') 'Reset to ', leaves%list(id)%p%par%Tgas
      call display_string_both(str_disp, a_book_keeping%fU)
    end if
    !
    write(*, '(2X, 2(2X, A, F12.3))') 'Tgas_new: ', leaves%list(id)%p%par%Tgas, &
      'Tdust: ', leaves%list(id)%p%par%Tdust
    !
    call chem_cal_rates
    !
    call realtime_heating_cooling_rate(tmp, &
         chemsol_params%NEQ, chemsol_stor%record(:, isav))
    leaves%list(id)%p%h_c_rates = heating_cooling_rates
    !
    call update_en_exchange_with_dust(leaves%list(id)%p%par)
    !
    if (a_disk_iter_params%flag_save_rates) then
      call save_chem_rates(id)
    end if
    !
    call update_params_above_alt(id)
    !
    ! Update local dynamical information
    call calc_local_dynamics(leaves%list(id)%p)
    !
    if (isnan(leaves%list(id)%p%par%pressure_thermal)) then
      write(str_disp, '(A, 4ES16.9)') 'Tgas,ngas,X_HI,X_H2:', &
        leaves%list(id)%p%par%Tgas, leaves%list(id)%p%par%n_gas, &
        leaves%list(id)%p%abundances(chem_idx_some_spe%i_HI), &
        leaves%list(id)%p%abundances(chem_idx_some_spe%i_H2)
      call display_string_both(str_disp, a_book_keeping%fU)
    end if
    !
    if ((leaves%list(id)%p%quality .eq. 0) .or. &
        (leaves%list(id)%p%par%t_final .ge. &
         0.3D0 * chemsol_params%t_max)) then
      exit
    end if
    !
  end do
  !
  if (a_disk_ana_params%do_analyse) then
    if ((a_disk_iter_params%n_iter_used .gt. 0) .and. &
        (is_in_list_int(id, ana_ptlist%nlen, ana_ptlist%vals))) then
      call chem_analyse(id)
    end if
  end if
  !
  nullify(chem_params)
  nullify(hc_params)
end subroutine calc_this_cell


subroutine update_en_exchange_with_dust(par)
  type(type_cell_rz_phy_basic), intent(inout) :: par
  integer i
  !
  par%en_exchange_tot = cooling_gas_grain_collision() * par%volume
  !
  ! This is the energy that the gas transfer to each type of dust per cell.
  ! Can be negative.
  if (a_disk%allow_gas_dust_en_exch) then
    do i=1, a_disk%ndustcompo
      par%en_exchange(i) = max(par%en_exchange_per_vol(i) * par%volume, &
                               -frac_dust_lose_en * hc_params%en_gains(i))
        !
    end do
  end if
end subroutine update_en_exchange_with_dust



subroutine update_params_above_alt(i0)
  use load_Visser_CO_selfshielding
  integer, intent(in) :: i0
  integer i
  !
  ! Calculate the column density of a few species to the star and to the ISM
  do i=1, chem_idx_some_spe%nItem
    call calc_Ncol_to_ISM(leaves%list(i0)%p, i)
    call calc_Ncol_to_Star(leaves%list(i0)%p, i)
  end do
  associate(c => leaves%list(i0)%p)
    ! Kwok eq 10.20
    ! c%par%Av_toISM = 1.086D0 * c%par%ratioDust2HnucNum * &
    !   (phy_Pi * c%par%GrainRadius_CGS**2) * 2D0 * c%par%Ncol_toISM
    ! c%par%Av_toStar = 1.086D0 * c%par%ratioDust2HnucNum * &
    !   (phy_Pi * c%par%GrainRadius_CGS**2) * 2D0 * c%par%Ncol_toStar
    !
    c%par%f_selfshielding_toISM_H2  = min(1D0, get_H2_self_shielding( &
      c%col_den_toISM(chem_idx_some_spe%iiH2), c%par%velo_width_turb))
    c%par%f_selfshielding_toStar_H2  = min(1D0, get_H2_self_shielding( &
      c%col_den_toStar(chem_idx_some_spe%iiH2), c%par%velo_width_turb))
    !
    ! H2O and OH self shielding are already taken into account in the radiative transfer.
    ! Only for output; not used.
    c%par%f_selfshielding_toISM_H2O = &
      min(1D0, exp(-(c%col_den_toISM(chem_idx_some_spe%iiH2O) * &
               const_LyAlpha_cross_H2O)))
    c%par%f_selfshielding_toStar_H2O = &
      min(1D0, exp(-(c%col_den_toStar(chem_idx_some_spe%iiH2O) * &
               const_LyAlpha_cross_H2O)))
    !
    c%par%f_selfshielding_toISM_OH = &
      min(1D0, exp(-(c%col_den_toISM(chem_idx_some_spe%iiOH) * &
               const_LyAlpha_cross_OH)))
    c%par%f_selfshielding_toStar_OH = &
      min(1D0, exp(-(c%col_den_toStar(chem_idx_some_spe%iiOH) * &
               const_LyAlpha_cross_OH)))
    !
    c%par%f_selfshielding_toISM_CO = min(1D0, max(0D0, get_12CO_shielding( &
      c%col_den_toISM(chem_idx_some_spe%iiH2), &
      c%col_den_toISM(chem_idx_some_spe%iiCO))))
    !
    c%par%f_selfshielding_toStar_CO = min(1D0, max(0D0, get_12CO_shielding( &
      c%col_den_toStar(chem_idx_some_spe%iiH2), &
      c%col_den_toStar(chem_idx_some_spe%iiCO))))
    !
    c%par%zeta_Xray_H2 = calc_Xray_ionization_rate(c)
    !
    ! Calculate the gravitational force from above
    if (c%above%n .eq. 0) then
      c%par%gravity_acc_z = &
        phy_GravitationConst_CGS * (a_star%mass * phy_Msun_CGS) * &
          (calc_Ncol_from_cell_to_point(leaves%list(i0)%p, &
                                        c%par%rcen, root%ymax*2D0, -4) * &
           c%par%area_T * phy_mProton_CGS * c%par%MeanMolWeight) * &
          (-c%ymax / (sqrt(c%xmax**2 + c%ymax**2))**3 / (phy_AU2cm**2))
    else
      c%par%gravity_acc_z = &
        calc_Ncol_from_cell_to_point(leaves%list(i0)%p, &
                                     c%par%rcen, root%ymax*2D0, -1)
    end if
    !
    if (.not. a_disk%waterShieldWithRadTran) then
      c%par%phflux_Lya = &
        c%par%flux_Lya_star_unatten / phy_LyAlpha_energy_CGS &
        * exp(-phy_UVext2Av * c%par%Av_toISM) &
        * c%par%f_selfshielding_toStar_H2O &
        * c%par%f_selfshielding_toStar_OH
      c%par%G0_Lya_atten = c%par%phflux_Lya / phy_Habing_photon_flux_CGS
    end if
  end associate
end subroutine update_params_above_alt



function get_H2_self_shielding(N_H2, dv_turb)
  ! Draine 1996, equation 37
  double precision get_H2_self_shielding
  double precision, intent(in) :: N_H2, dv_turb
  double precision x, b5
  x = N_H2 / 5D14
  b5 = dv_turb / 1D5
  get_H2_self_shielding = 0.965D0 / (1D0 + x/b5)**2 + &
    0.035 / sqrt(1D0 + x) * exp(-8.5D-4 * sqrt(1D0 + x))
end function get_H2_self_shielding



subroutine check_convergency_cell(i0)
  integer, intent(in) :: i0
  ! Temperature is not considered.
  if (maxval(abs(leaves%list(i0)%p%abundances(chem_idx_some_spe%idx) &
                 - a_iter_stor%abundances(:, i0)) &
             - (a_disk_iter_params%atol_abun + &
                a_disk_iter_params%rtol_abun * &
                abs(leaves%list(i0)%p%abundances(chem_idx_some_spe%idx) &
                  + a_iter_stor%abundances(:, i0))) &
            ) .le. 0D0) then
    leaves%list(i0)%p%converged = .true.
  else
    leaves%list(i0)%p%converged = .false.
  end if
end subroutine check_convergency_cell



subroutine check_convergency_whole_disk
  integer i
  a_disk_iter_params%n_cell_converged = 0
  do i=1, leaves%nlen
    if (leaves%list(i)%p%converged) then
      a_disk_iter_params%n_cell_converged = a_disk_iter_params%n_cell_converged + 1
    end if
  end do
  a_disk_iter_params%flag_converged = &
    a_disk_iter_params%n_cell_converged .ge. &
    int(a_disk_iter_params%converged_cell_percentage_stop * real(leaves%nlen))
  write(str_disp, '("! Iter", I4, 4X, "Number of cells converged: ", I6, "/", I6)') &
    a_disk_iter_params%n_iter_used, a_disk_iter_params%n_cell_converged, leaves%nlen
  call display_string_both(str_disp, a_book_keeping%fU)
end subroutine check_convergency_whole_disk



subroutine update_calculating_cells
  integer, dimension(:), allocatable :: list_tmp
  integer i, i0, itmp, j, k, n
  logical flag_notyet
  allocate(list_tmp(n_calculating_cells_max))
  n = 0
  do i=1, n_calculating_cells
    i0 = calculating_cells(i)
    do j=1, leaves%list(i0)%p%below%n
      itmp = leaves%list(i0)%p%below%idx(j)
      flag_notyet = .true.
      do k=1, n
        if (list_tmp(k) .eq. itmp) then
          flag_notyet = .false.
          exit
        end if
      end do
      if (flag_notyet) then
        n = n + 1
        list_tmp(n) = itmp
      end if
    end do
  end do
  n_calculating_cells = n
  if (n .ge. 1) then
    calculating_cells(1:n) = list_tmp(1:n)
  end if
  deallocate(list_tmp)
end subroutine update_calculating_cells



function calc_Xray_ionization_rate(c) result(z_Xray)
  ! Ionization rate per H atom
  use load_Bethell_Xray_cross
  double precision z_Xray
  type(type_cell), intent(in) :: c
  integer i, i1, i2
  double precision lam, en, sig
  double precision, parameter :: en_per_ion = 37D0 ! eV
  i1 = max(1, get_idx_for_kappa(lam_range_Xray(1), dust_0))
  i2 = min(dust_0%n, get_idx_for_kappa(lam_range_Xray(2), dust_0))
  z_Xray = 0D0
  do i=i1, i2
    lam = dust_0%lam(i)
    en = phy_hPlanck_CGS * phy_SpeedOfLight_CGS &
         / (lam * 1D-8) / phy_eV2erg / 1D3 ! in keV
    sig = sigma_Xray_Bethell(en, c%par%dust_depletion, &
          c%par%ratioDust2HnucNum, c%par%GrainRadius_CGS)
    z_Xray = z_Xray + &
             c%optical%flux(i) / (en * 1D3 * phy_eV2erg) * &
             sig * (en * 1D3 / en_per_ion)
  end do
end function calc_Xray_ionization_rate



subroutine set_initial_condition_4solver(id, j, iiter)
  integer, intent(in) :: id, j, iiter
  integer flag
  double precision, parameter :: nOrbit=1D3
  !
  flag = 0
  if (iiter .gt. 1) then
    flag = 10
  end if
  if (j .gt. 1) then
    flag = flag + 1
  end if
  select case(flag)
    case(0) ! iiter=1, j=1
      leaves%list(id)%p%par%Tgas = leaves%list(id)%p%par%Tdust
    case(1, 11) ! iiter=1, j>1
      if (leaves%list(id)%p%above%n .gt. 0) then
        leaves%list(id)%p%par%Tgas = &
          leaves%list(leaves%list(id)%p%above%idx(1))%p%par%Tgas
      else
        leaves%list(id)%p%par%Tgas = dble(j+1) * leaves%list(id)%p%par%Tdust
      end if
    case(10) ! iiter>1, j=1
      ! Do nothing
  end select
  !
  if (isnan(leaves%list(id)%p%par%Tgas)) then
    leaves%list(id)%p%par%Tgas = dble(iiter+1) * leaves%list(id)%p%par%Tdust
  end if
  !
  chemsol_stor%y(1:chem_species%nSpecies) = &
    chemsol_stor%y0(1:chem_species%nSpecies)
  !
  if (chem_idx_some_spe%i_Grain0 .ne. 0) then
    ! Initial abundance of *neutral* dust
    ! There should be no dust in the input initial abundance file
    chemsol_stor%y(chem_idx_some_spe%i_Grain0) = &
        leaves%list(id)%p%par%ratioDust2HnucNum
  end if
  !
  chemsol_stor%y(chem_species%nSpecies+1) = leaves%list(id)%p%par%Tgas
  !
  chemsol_params%evolT = .true.
  chemsol_params%maySwitchT = .true.
  if (leaves%list(id)%p%par%en_gain_tot .le. 0D0) then
    chemsol_params%evolT = .false.
  end if
  !
  chemsol_params%t0 = 0D0
  chemsol_params%dt_first_step = chemsol_params%dt_first_step0
  !
  chemsol_params%t_max = min(chemsol_params%t_max0, &
    nOrbit * phy_2Pi/leaves%list(id)%p%par%omega_Kepler/phy_SecondsPerYear)
  !
  call chem_evol_solve_prepare_ongoing
  !
end subroutine set_initial_condition_4solver



subroutine set_initial_condition_4solver_continue(id)
  integer, intent(in) :: id
  associate(c => leaves%list(id)%p)
    !
    !if ((c%par%t_final .ge. 2D0 * chemsol_params%t0) .and. &
    !    (abs(c%par%Tgas - chemsol_stor%y(chem_species%nSpecies+1)) .le. &
    !     1D-2*(c%par%Tgas + chemsol_stor%y(chem_species%nSpecies+1)))) then
    !  chemsol_params%evolT = .false.
    !  chemsol_params%maySwitchT = .true.
    !else
    chemsol_params%evolT = .true.
    chemsol_params%maySwitchT = .true.
    if (leaves%list(id)%p%par%en_gain_tot .le. 0D0) then
      chemsol_params%evolT = .false.
    end if
    !end if
    !
    chemsol_stor%y(1:chem_species%nSpecies) = c%abundances
    chemsol_stor%y(chem_species%nSpecies+1) = c%par%Tgas
    !
    chemsol_params%t0 = c%par%t_final
    chemsol_params%dt_first_step = &
      max(chemsol_params%dt_first_step0, chemsol_params%t0*1D-2)
    !
  end associate
  !
  call chem_evol_solve_prepare_ongoing
  !
end subroutine set_initial_condition_4solver_continue




subroutine make_columns
  integer i, j, i1
  type(type_cell), pointer :: cthis, cnext
  double precision length, r, z, eps
  integer dirtype, n_using
  logical found
  type(type_ray) ray
  !
  allocate(columns(bott_cells%nlen), columns_idx(bott_cells%nlen))
  do i=1, bott_cells%nlen
    cthis => leaves%list(bott_cells%idx(i))%p
    r = cthis%par%rcen
    z = root%ymax * 2D0
    columns(i)%nlen = int(calc_Ncol_from_cell_to_point(cthis, r, z, -2))
    if (.not. allocated(columns(i)%list)) then
      allocate(columns(i)%list(columns(i)%nlen))
    end if
    !
    ray%x = cthis%par%rcen
    ray%y = 0D0
    ray%z = cthis%par%zcen
    ray%vx = 0D0
    ray%vy = 0D0
    ray%vz = 1D0
    !
    n_using = 0
    j = 0
    ! First make a list of all the cells (including null ones) above the bottom
    ! (mid-plane) one.  They are ordered from bottom to top.
    do
      call calc_intersection_ray_cell(ray, cthis, &
        length, r, z, eps, found, dirtype)
      if (.not. found) then
        write(str_disp,'(A)') 'In make_columns:'
        call display_string_both(str_disp, a_book_keeping%fU)
        write(str_disp,'(A, 9ES16.6)') 'ray does not intersect cthis: ', &
          sqrt(ray%x**2+ray%y**2), ray%z, ray%vx, ray%vy, ray%vz, &
            cthis%xmin, cthis%xmax, cthis%ymin, cthis%ymax
        call display_string_both(str_disp, a_book_keeping%fU)
        write(*, *)
        return
      end if
      !
      j = j + 1
      columns(i)%list(j)%p => cthis
      if (columns(i)%list(j)%p%id .gt. 0) then
        n_using = n_using + 1
      end if
      !
      ray%x = ray%x + ray%vx * (length + eps)
      ray%y = ray%y + ray%vy * (length + eps)
      ray%z = ray%z + ray%vz * (length + eps)
      !
      call locate_photon_cell_alt(r, z, cthis, dirtype, cnext, found)
      if (found) then
        cthis => cnext
      else
        exit
      end if
    end do
    !
    columns_idx(i)%nlen = n_using
    allocate(columns_idx(i)%vals(n_using))
    i1 = n_using + 1
    do j=1, columns(i)%nlen
      if (columns(i)%list(j)%p%id .gt. 0) then
         i1 = i1 - 1
        columns_idx(i)%vals(i1) = columns(i)%list(j)%p%id
      end if
    end do
  end do
end subroutine make_columns



subroutine calc_Ncol_to_ISM(c, iSp)
  ! iSp is the index in chem_idx_some_spe, not in the range 1 to
  ! chem_species%nSpecies
  type(type_cell), intent(inout), pointer :: c
  integer, intent(in), optional :: iSp
  if (present(iSp)) then
    c%col_den_toISM(iSp) = calc_Ncol_from_cell_to_point( &
      c, c%par%rcen, root%ymax * 2D0, &
      chem_idx_some_spe%idx(iSp))
  else
    c%par%Ncol_toISM = calc_Ncol_from_cell_to_point( &
      c, c%par%rcen, root%ymax * 2D0)
  end if
end subroutine calc_Ncol_to_ISM



subroutine calc_Ncol_to_Star(c, iSp)
  ! iSp is the index in chem_idx_some_spe, not in the range 1 to
  ! chem_species%nSpecies
  type(type_cell), intent(inout), pointer :: c
  integer, intent(in), optional :: iSp
  if (present(iSp)) then
    c%col_den_toStar(iSp) = calc_Ncol_from_cell_to_point( &
      c, 0D0, 0D0, chem_idx_some_spe%idx(iSp))
  else
    c%par%Ncol_toStar = calc_Ncol_from_cell_to_point( &
      c, 0D0, 0D0)
  end if
end subroutine calc_Ncol_to_Star



function calc_Ncol_from_cell_to_point(c, r, z, iSpe) result(N)
  double precision N
  type(type_cell), intent(in), target :: c ! Todo: pointer or not?
  double precision, intent(in) :: r, z
  integer, intent(in), optional :: iSpe
  type(type_ray) ray
  type(type_cell), pointer :: cthis, cnext
  double precision t, length, r1, z1, eps
  logical found
  integer dirtype
  double precision, parameter :: small_dist = 1D-50
  !
  N = 0D0
  !
  ray%x = c%par%rcen
  ray%y = 0D0
  ray%z = c%par%zcen
  !
  ray%vx = r - ray%x
  ray%vy = 0D0
  ray%vz = z - ray%z
  t = sqrt(ray%vx**2 + ray%vy**2 + ray%vz**2)
  if (t .le. small_dist) then
    return
  end if
  ray%vx = ray%vx / t
  ray%vy = ray%vy / t
  ray%vz = ray%vz / t
  !
  cthis => c
  !
  do
    call calc_intersection_ray_cell(ray, cthis, &
        length, r1, z1, eps, found, dirtype)
    if (.not. found) then
      write(str_disp,'(A, 9ES13.4)') &
        'In calc_Ncol_from_cell_to_point: ray does not intersect cthis: ', &
        sqrt(ray%x**2+ray%y**2), ray%z, ray%vx, ray%vy, ray%vz, &
            cthis%xmin, cthis%xmax, cthis%ymin, cthis%ymax
      call display_string_both(str_disp, a_book_keeping%fU)
      exit
    end if
    !
    if (present(iSpe)) then
      if ((iSpe .ge. 1) .and. (iSpe .le. chem_species%nSpecies)) then
        ! Calculate column density of a species
        if (cthis%using) then
          N = N + cthis%par%n_gas * cthis%abundances(iSpe) * &
              (length * phy_AU2cm)
        end if
      !
      else if (iSpe .eq. 0) then
        ! Calculate column density
        if (cthis%using) then
          N = N + cthis%par%n_gas * length * phy_AU2cm
        end if
      !
      else if (iSpe .eq. -1) then
        ! Calculate gravity force (accumulated), not including the gravity of
        ! the starting cell.
        if ((cthis%xmin .ne. c%xmin) .or. (cthis%xmax .ne. c%xmax) .or. &
            (cthis%ymin .ne. c%ymin) .or. (cthis%ymax .ne. c%ymax)) then
          if (cthis%using) then
            N = N + cthis%par%gravity_z
          end if
        end if
      !
      else if (iSpe .eq. -2) then
        ! Calculate the number of cells crossed by the ray.
        N = N + 1D0
      !
      else if (iSpe .eq. -3) then
        ! Calculate column density, including null cells.
        ! Density is taken from the initial value
        N = N + cthis%val(1) * length * phy_AU2cm
      !
      else if (iSpe .eq. -4) then
        ! Calculate column density, including null cells, but not itself.
        if ((cthis%xmin .ne. c%xmin) .or. (cthis%xmax .ne. c%xmax) .or. &
            (cthis%ymin .ne. c%ymin) .or. (cthis%ymax .ne. c%ymax)) then
          N = N + cthis%val(1) * length * phy_AU2cm
        end if
      !
      else if (iSpe .eq. -5) then
        ! Calculate the dust column density
        if ((cthis%xmin .ne. c%xmin) .or. (cthis%xmax .ne. c%xmax) .or. &
            (cthis%ymin .ne. c%ymin) .or. (cthis%ymax .ne. c%ymax)) then
          if (cthis%using) then
            N = N + cthis%par%ndust_tot * length * phy_AU2cm
          end if
        end if
      else
        write(str_disp,'(A)') 'I do not know what to do!'
        call display_string_both(str_disp, a_book_keeping%fU)
        stop
      end if
    else
      ! Calculate column density by default
      if (cthis%using) then
        N = N + cthis%par%n_gas * length * phy_AU2cm
      end if
    end if
    !
    ray%x = ray%x + ray%vx * (length + eps)
    ray%y = ray%y + ray%vy * (length + eps)
    ray%z = ray%z + ray%vz * (length + eps)
    !
    call locate_photon_cell_alt(r1, z1, cthis, dirtype, cnext, found)
    if (found) then
      cthis => cnext
    else
      exit
    end if
  end do
  !
  if (present(iSpe)) then
    if (iSpe .eq. -1) then
      if (cthis%using) then
        N = N + cthis%par%gravity_acc_z
      end if
    end if
  end if
end function calc_Ncol_from_cell_to_point



subroutine disk_save_results_pre
  write(filename_save_results, '("iter_", I4.4, ".dat")') &
    a_disk_iter_params%n_iter_used
  filename_save_results = trim(combine_dir_filename( &
    a_disk_iter_params%iter_files_dir, filename_save_results))
  call openFileSequentialWrite(fU_save_results, filename_save_results, &
       99999, getu=1)
  !
  call write_header(fU_save_results)
end subroutine disk_save_results_pre


subroutine write_header(fU)
  integer, intent(in) :: fU
  character(len=64) fmt_str
  character(len=10000) tmp_str
  write(fmt_str, '("(", I4, "A14)")') chem_species%nSpecies
  write(tmp_str, fmt_str) chem_species%names
  write(fU, '(A)') &
    '!' // &
    str_pad_to_len('cvg',  4) // &
    str_pad_to_len('qual', 5) // &
    str_pad_to_len('cr_count',len_item) // &
    str_pad_to_len('abc_dus', len_item) // &
    str_pad_to_len('scc_HI',  len_item) // &
    str_pad_to_len('abc_wat', len_item) // &
    str_pad_to_len('t_final', len_item) // &
    str_pad_to_len('rmin',    len_item) // &
    str_pad_to_len('rmax',    len_item) // &
    str_pad_to_len('zmin',    len_item) // &
    str_pad_to_len('zmax',    len_item) // &
    str_pad_to_len('Tgas',    len_item) // &
    str_pad_to_len('Tdust',   len_item) // &
    str_pad_to_len('Tdust1',  len_item) // &
    str_pad_to_len('Tdust2',  len_item) // &
    str_pad_to_len('Tdust3',  len_item) // &
    str_pad_to_len('Tdust4',  len_item) // &
    str_pad_to_len('n_gas',   len_item) // &
    str_pad_to_len('ndust_t', len_item) // &
    str_pad_to_len('sigd_av', len_item) // &
    str_pad_to_len('d2gmas',  len_item) // &
    str_pad_to_len('d2gnum',  len_item) // &
    str_pad_to_len('deplet',  len_item) // &
    str_pad_to_len('mg_cell', len_item) // &
    str_pad_to_len('md_cell', len_item) // &
    str_pad_to_len('presr_t', len_item) // &
    str_pad_to_len('presr_g', len_item) // &
    str_pad_to_len('egain_d', len_item) // &
    str_pad_to_len('egain_ab',len_item) // &
    str_pad_to_len('egain_e', len_item) // &
    str_pad_to_len('egain_d1', len_item) // &
    str_pad_to_len('egain_e1', len_item) // &
    str_pad_to_len('egain_d2', len_item) // &
    str_pad_to_len('egain_e2', len_item) // &
    str_pad_to_len('egain_d3', len_item) // &
    str_pad_to_len('egain_e3', len_item) // &
    str_pad_to_len('egain_d4', len_item) // &
    str_pad_to_len('egain_e4', len_item) // &
    str_pad_to_len('flx_tot', len_item) // &
    str_pad_to_len('flx_Xray',len_item) // &
    str_pad_to_len('G0_UV',   len_item) // &
    str_pad_to_len('flx_Lya', len_item) // &
    str_pad_to_len('flx_Vis', len_item) // &
    str_pad_to_len('flx_NIR', len_item) // &
    str_pad_to_len('flx_MIR', len_item) // &
    str_pad_to_len('flx_FIR', len_item) // &
    str_pad_to_len('vr_tot',  len_item) // &
    str_pad_to_len('vz_tot',  len_item) // &
    str_pad_to_len('ani_tot', len_item) // &
    str_pad_to_len('vr_Xray', len_item) // &
    str_pad_to_len('vz_Xray', len_item) // &
    str_pad_to_len('ani_Xray',len_item) // &
    str_pad_to_len('vr_UV',   len_item) // &
    str_pad_to_len('vz_UV',   len_item) // &
    str_pad_to_len('ani_UV',  len_item) // &
    str_pad_to_len('vr_Lya',  len_item) // &
    str_pad_to_len('vz_Lya',  len_item) // &
    str_pad_to_len('ani_Lya', len_item) // &
    str_pad_to_len('vr_Vis',  len_item) // &
    str_pad_to_len('vz_Vis',  len_item) // &
    str_pad_to_len('ani_Vis', len_item) // &
    str_pad_to_len('vr_NIR',  len_item) // &
    str_pad_to_len('vz_NIR',  len_item) // &
    str_pad_to_len('ani_NIR', len_item) // &
    str_pad_to_len('vr_MIR',  len_item) // &
    str_pad_to_len('vz_MIR',  len_item) // &
    str_pad_to_len('ani_MIR', len_item) // &
    str_pad_to_len('vr_FIR',  len_item) // &
    str_pad_to_len('vz_FIR',  len_item) // &
    str_pad_to_len('ani_FIR', len_item) // &
    str_pad_to_len('Av_ISM',  len_item) // &
    str_pad_to_len('Av_Star', len_item) // &
    str_pad_to_len('UV_G0_I', len_item) // &
    str_pad_to_len('UV_G0_S', len_item) // &
    str_pad_to_len('LyAG0_a', len_item) // &
    str_pad_to_len('LyANF0',  len_item) // &
    str_pad_to_len('zeta_X',  len_item) // &
    str_pad_to_len('Ncol_I',  len_item) // &
    str_pad_to_len('Ncol_S',  len_item) // &
    str_pad_to_len('N_H2_I',  len_item) // &
    str_pad_to_len('N_H2O_I', len_item) // &
    str_pad_to_len('N_OH_I',  len_item) // &
    str_pad_to_len('N_CO_I',  len_item) // &
    str_pad_to_len('N_H2_S',  len_item) // &
    str_pad_to_len('N_H2O_S', len_item) // &
    str_pad_to_len('N_OH_S',  len_item) // &
    str_pad_to_len('N_CO_S',  len_item) // &
    str_pad_to_len('f_H2_I',  len_item) // &
    str_pad_to_len('f_H2O_I', len_item) // &
    str_pad_to_len('f_OH_I',  len_item) // &
    str_pad_to_len('f_CO_I',  len_item) // &
    str_pad_to_len('f_H2_S',  len_item) // &
    str_pad_to_len('f_H2O_S', len_item) // &
    str_pad_to_len('f_OH_S',  len_item) // &
    str_pad_to_len('f_CO_S',  len_item) // &
    str_pad_to_len('R_H2_fo', len_item) // &
    str_pad_to_len('hc_net',  len_item) // &
    str_pad_to_len('h_ph_gr', len_item) // &
    str_pad_to_len('h_fo_H2', len_item) // &
    str_pad_to_len('h_cosmi', len_item) // &
    str_pad_to_len('h_vi_H2', len_item) // &
    str_pad_to_len('h_io_CI', len_item) // &
    str_pad_to_len('h_ph_H2', len_item) // &
    str_pad_to_len('h_ph_wa', len_item) // &
    str_pad_to_len('h_ph_OH', len_item) // &
    str_pad_to_len('h_Xray ', len_item) // &
    str_pad_to_len('h_visco', len_item) // &
    str_pad_to_len('h_chem',  len_item) // &
    str_pad_to_len('c_el_gr', len_item) // &
    str_pad_to_len('c_vi_H2', len_item) // &
    str_pad_to_len('c_gg_co', len_item) // &
    str_pad_to_len('c_OI   ', len_item) // &
    str_pad_to_len('c_CII  ', len_item) // &
    str_pad_to_len('c_wa_ro', len_item) // &
    str_pad_to_len('c_wa_vi', len_item) // &
    str_pad_to_len('c_CO_ro', len_item) // &
    str_pad_to_len('c_CO_vi', len_item) // &
    str_pad_to_len('c_H2_ro', len_item) // &
    str_pad_to_len('c_LyAlp', len_item) // &
    str_pad_to_len('c_fb   ', len_item) // &
    str_pad_to_len('c_ff   ', len_item) // &
    str_pad_to_len('alpha  ', len_item) // &
    str_pad_to_len('am     ', len_item) // &
    str_pad_to_len('ion_cha', len_item) // &
    str_pad_to_len('v_Kep',   len_item) // &
    str_pad_to_len('w_Kep',   len_item) // &
    str_pad_to_len('dv_dr',   len_item) // &
    str_pad_to_len('c_sound', len_item) // &
    str_pad_to_len('dv_turb', len_item) // &
    str_pad_to_len('l_coher', len_item) // &
    trim(tmp_str)
end subroutine write_header


subroutine disk_save_results_write(fU, c)
  character(len=64) fmt_str
  integer, intent(in) :: fU
  type(type_cell), pointer, intent(in) :: c
  integer converged
  !
  write(fmt_str, '(", ", I4, "ES14.5E3)")') chem_species%nSpecies
  if (c%converged) then
    converged = 1
  else
    converged = 0
  end if
  write(fU, '(2I5, 4I14, 124ES14.5E3' // trim(fmt_str)) &
  converged                                              , &
  c%quality                                              , &
  c%optical%cr_count                                     , &
  c%par%ab_count_dust                                    , &
  c%par%sc_count_HI                                      , &
  c%par%ab_count_water                                   , &
  c%par%t_final                                          , &
  c%par%rmin                                             , &
  c%par%rmax                                             , &
  c%par%zmin                                             , &
  c%par%zmax                                             , &
  c%par%Tgas                                             , &
  c%par%Tdust                                            , &
  c%par%Tdusts(1)                                        , &
  c%par%Tdusts(2)                                        , &
  c%par%Tdusts(3)                                        , &
  c%par%Tdusts(4)                                        , &
  c%par%n_gas                                            , &
  c%par%ndust_tot                                        , &
  c%par%sigdust_ave                                      , &
  c%par%ratioDust2GasMass                                , &
  c%par%ratioDust2HnucNum                                , &
  c%par%dust_depletion                                   , &
  c%par%mgas_cell                                        , &
  c%par%mdust_tot                                        , &
  c%par%pressure_thermal                                 , &
  c%par%gravity_acc_z / c%par%area_T                     , &
  c%par%en_gain_tot                                      , &
  c%par%en_gain_abso_tot                                 , &
  c%par%en_exchange_tot                                  , &
  c%par%en_gains(1)                                      , &
  c%par%en_exchange(1)                                   , &
  c%par%en_gains(2)                                      , &
  c%par%en_exchange(2)                                   , &
  c%par%en_gains(3)                                      , &
  c%par%en_exchange(3)                                   , &
  c%par%en_gains(4)                                      , &
  c%par%en_exchange(4)                                   , &
  c%par%flux_tot                                         , &
  c%par%flux_Xray                                        , &
  c%par%flux_UV/phy_Habing_energy_flux_CGS               , &
  c%par%flux_Lya                                         , &
  c%par%flux_Vis                                         , &
  c%par%flux_NIR                                         , &
  c%par%flux_MIR                                         , &
  c%par%flux_FIR                                         , &
  c%par%dir_tot_r                                        , &
  c%par%dir_tot_z                                        , &
  c%par%aniso_tot                                        , &
  c%par%dir_Xray_r                                       , &
  c%par%dir_Xray_z                                       , &
  c%par%aniso_Xray                                       , &
  c%par%dir_UV_r                                         , &
  c%par%dir_UV_z                                         , &
  c%par%aniso_UV                                         , &
  c%par%dir_Lya_r                                        , &
  c%par%dir_Lya_z                                        , &
  c%par%aniso_Lya                                        , &
  c%par%dir_Vis_r                                        , &
  c%par%dir_Vis_z                                        , &
  c%par%aniso_Vis                                        , &
  c%par%dir_NIR_r                                        , &
  c%par%dir_NIR_z                                        , &
  c%par%aniso_NIR                                        , &
  c%par%dir_MIR_r                                        , &
  c%par%dir_MIR_z                                        , &
  c%par%aniso_MIR                                        , &
  c%par%dir_FIR_r                                        , &
  c%par%dir_FIR_z                                        , &
  c%par%aniso_FIR                                        , &
  c%par%Av_toISM                                         , &
  c%par%Av_toStar                                        , &
  c%par%G0_UV_toISM                                      , &
  c%par%G0_UV_toStar                                     , &
  c%par%G0_Lya_atten                                     , &
  c%par%phflux_Lya                                       , &
  c%par%zeta_Xray_H2                                     , &
  c%par%Ncol_toISM                                       , &
  c%par%Ncol_toStar                                      , &
  c%col_den_toISM(chem_idx_some_spe%iiH2)                , &
  c%col_den_toISM(chem_idx_some_spe%iiH2O)               , &
  c%col_den_toISM(chem_idx_some_spe%iiOH)                , &
  c%col_den_toISM(chem_idx_some_spe%iiCO)                , &
  c%col_den_toStar(chem_idx_some_spe%iiH2)               , &
  c%col_den_toStar(chem_idx_some_spe%iiH2O)              , &
  c%col_den_toStar(chem_idx_some_spe%iiOH)               , &
  c%col_den_toStar(chem_idx_some_spe%iiCO)               , &
  c%par%f_selfshielding_toISM_H2                         , &
  c%par%f_selfshielding_toISM_H2O                        , &
  c%par%f_selfshielding_toISM_OH                         , &
  c%par%f_selfshielding_toISM_CO                         , &
  c%par%f_selfshielding_toStar_H2                        , &
  c%par%f_selfshielding_toStar_H2O                       , &
  c%par%f_selfshielding_toStar_OH                        , &
  c%par%f_selfshielding_toStar_CO                        , &
  c%par%R_H2_form_rate                                   , &
  c%h_c_rates%hc_net_rate                                , &
  c%h_c_rates%heating_photoelectric_small_grain_rate     , &
  c%h_c_rates%heating_formation_H2_rate                  , &
  c%h_c_rates%heating_cosmic_ray_rate                    , &
  c%h_c_rates%heating_vibrational_H2_rate                , &
  c%h_c_rates%heating_ionization_CI_rate                 , &
  c%h_c_rates%heating_photodissociation_H2_rate          , &
  c%h_c_rates%heating_photodissociation_H2O_rate         , &
  c%h_c_rates%heating_photodissociation_OH_rate          , &
  c%h_c_rates%heating_Xray_Bethell_rate                  , &
  c%h_c_rates%heating_viscosity_rate                     , &
  c%h_c_rates%heating_chem                               , &
  c%h_c_rates%cooling_photoelectric_small_grain_rate     , &
  c%h_c_rates%cooling_vibrational_H2_rate                , &
  c%h_c_rates%cooling_gas_grain_collision_rate           , &
  c%h_c_rates%cooling_OI_rate                            , &
  c%h_c_rates%cooling_CII_rate                           , &
  c%h_c_rates%cooling_Neufeld_H2O_rate_rot               , &
  c%h_c_rates%cooling_Neufeld_H2O_rate_vib               , &
  c%h_c_rates%cooling_Neufeld_CO_rate_rot                , &
  c%h_c_rates%cooling_Neufeld_CO_rate_vib                , &
  c%h_c_rates%cooling_Neufeld_H2_rot_rate                , &
  c%h_c_rates%cooling_LymanAlpha_rate                    , &
  c%h_c_rates%cooling_free_bound_rate                    , &
  c%h_c_rates%cooling_free_free_rate                     , &
  c%par%alpha_viscosity                                  , &
  c%par%ambipolar_f                                      , &
  c%par%ion_charge                                       , &
  c%par%velo_Kepler                                      , &
  c%par%omega_Kepler                                     , &
  c%par%velo_gradient                                    , &
  c%par%sound_speed                                      , &
  c%par%velo_width_turb                                  , &
  c%par%coherent_length                                  , &
  c%abundances
end subroutine disk_save_results_write


subroutine disk_calc_disk_mass
  integer i
  a_disk%disk_mass_in_Msun = 0D0
  do i=1, leaves%nlen
    associate(p => leaves%list(i)%p%par)
      a_disk%disk_mass_in_Msun = &
        a_disk%disk_mass_in_Msun + &
        p%mgas_cell * 2D0 ! Accounts for the z<0 side
        !p%n_gas * p%MeanMolWeight * (phy_2Pi * p%rcen * p%dr * p%dz)
    end associate
  end do
  a_disk%disk_mass_in_Msun = a_disk%disk_mass_in_Msun / phy_Msun_CGS
end subroutine disk_calc_disk_mass


subroutine set_heatingcooling_params_from_cell(id)
  integer id
  hc_params%Neufeld_dv_dz = hc_params%velo_gradient * 1D-5 ! cm s-1 to km s-1
  hc_params%Neufeld_G     = 1D0
  hc_params%X_H2    = leaves%list(id)%p%abundances(chem_idx_some_spe%i_H2)
  hc_params%X_HI    = leaves%list(id)%p%abundances(chem_idx_some_spe%i_HI)
  hc_params%X_CI    = leaves%list(id)%p%abundances(chem_idx_some_spe%i_CI)
  hc_params%X_Cplus = leaves%list(id)%p%abundances(chem_idx_some_spe%i_Cplus)
  hc_params%X_OI    = leaves%list(id)%p%abundances(chem_idx_some_spe%i_OI)
  hc_params%X_CO    = leaves%list(id)%p%abundances(chem_idx_some_spe%i_CO)
  hc_params%X_H2O   = leaves%list(id)%p%abundances(chem_idx_some_spe%i_H2O)
  hc_params%X_OH    = leaves%list(id)%p%abundances(chem_idx_some_spe%i_OH)
  hc_params%X_E     = leaves%list(id)%p%abundances(chem_idx_some_spe%i_E)
  hc_params%X_Hplus = leaves%list(id)%p%abundances(chem_idx_some_spe%i_Hplus)
  if (chem_idx_some_spe%i_gH .gt. 0) then
    hc_params%X_gH   = leaves%list(id)%p%abundances(chem_idx_some_spe%i_gH)
    hc_params%X_gH2  = leaves%list(id)%p%abundances(chem_idx_some_spe%i_gH2)
  end if
  !
  hc_params%R_H2_form_rate = &
    get_H2_form_rate( &
      hc_params%R_H2_form_rate_coeff, &
      hc_params%X_gH, &
      hc_params%X_HI, &
      hc_params%n_gas)
  !
end subroutine set_heatingcooling_params_from_cell


subroutine disk_set_a_cell_params(c, cell_params_copy)
  integer i
  type(type_cell), target :: c
  type(type_cell_rz_phy_basic), intent(in) :: cell_params_copy
  if (.not. associated(c%par)) then
    allocate(c%par)
  end if
  if (.not. allocated(c%h_c_rates)) then
    allocate(c%h_c_rates)
  end if
  !
  if (.not. allocated(c%abundances)) then
    allocate(c%abundances(chem_species%nSpecies), &
             c%col_den_toISM(chem_idx_some_spe%nItem), &
             c%col_den_toStar(chem_idx_some_spe%nItem))
  end if
  !
  c%iIter = 0
  c%quality = 0
  !
  c%abundances(1:chem_species%nSpecies) = chemsol_stor%y0(1:chem_species%nSpecies)
  c%col_den_toISM = 0D0
  c%col_den_toStar = 0D0
  !
  c%par = cell_params_copy
  !
  c%par%rmin = c%xmin
  c%par%rmax = c%xmax
  c%par%rcen = (c%xmax + c%xmin) * 0.5D0
  c%par%dr   = c%xmax - c%xmin
  !
  c%par%zmin = c%ymin
  c%par%zmax = c%ymax
  c%par%zcen = (c%ymax + c%ymin) * 0.5D0
  c%par%dz   = c%ymax - c%ymin
  !
  c%par%volume = phy_Pi * (c%par%rmax + c%par%rmin) * &
                 c%par%dr * c%par%dz * phy_AU2cm**3
  c%par%area_T = phy_Pi * (c%par%rmax + c%par%rmin) * c%par%dr * phy_AU2cm**2
  c%par%area_B = phy_Pi * (c%par%rmax + c%par%rmin) * c%par%dr * phy_AU2cm**2
  c%par%area_I = phy_2Pi * c%par%rmin * c%par%dz * phy_AU2cm**2
  c%par%area_O = phy_2Pi * c%par%rmax * c%par%dz * phy_AU2cm**2
  c%par%surf_area = c%par%area_T + c%par%area_B + c%par%area_I + c%par%area_O
  !
  ! Get gas number density and gas mass in each cell
  a_disk%andrews_gas%particlemass = c%par%MeanMolWeight * phy_mProton_CGS
  c%par%n_gas = get_ave_val_analytic(c%xmin, c%xmax, c%ymin, c%ymax, &
                                     a_disk%andrews_gas)
  c%par%mgas_cell = c%par%n_gas * c%par%volume * &
                    (phy_mProton_CGS * c%par%MeanMolWeight)
  !
  c%par%mdust_tot = 0D0
  c%par%ndust_tot = 0D0
  c%par%sigdust_ave = 0D0
  !
  c%par%ndustcompo = a_disk%ndustcompo
  !
  do i=1, a_disk%ndustcompo
    ! Dust mass density
    c%par%rho_dusts(i) = get_ave_val_analytic( &
            c%xmin, c%xmax, c%ymin, c%ymax, &
            a_disk%dustcompo(i)%andrews)
    c%par%mp_dusts(i) = a_disk%dustcompo(i)%pmass_CGS ! Dust particle mass in gram
    c%par%n_dusts(i) = c%par%rho_dusts(i) / c%par%mp_dusts(i)
    c%par%mdusts_cell(i) = c%par%rho_dusts(i) * c%par%volume
    !
    if (c%par%n_dusts(i) .le. 1D-100) then
      ! If the dust density is very small, then set the density to absolute zero.
      c%par%n_dusts(i) = 0D0
      c%par%mdusts_cell(i) = 0D0
    end if
    !
    c%par%en_exchange(i) = 0D0
    c%par%en_exchange_per_vol(i) = 0D0
    !
    c%par%mdust_tot = c%par%mdust_tot + c%par%mdusts_cell(i)
    c%par%ndust_tot = c%par%ndust_tot + c%par%n_dusts(i)
    c%par%sig_dusts(i) = phy_Pi * a_disk%dustcompo(i)%mrn%r2av * &
                         phy_micron2cm**2
    c%par%sigdust_ave = c%par%sigdust_ave + c%par%n_dusts(i) * &
                        c%par%sig_dusts(i)
    write(str_disp, '(A, 2ES16.6, A, I2, A, ES12.3, A, ES12.3)') &
        'xymin:', c%xmin, c%ymin, ' Dust:', i, ' n_d:', c%par%n_dusts(i), &
        ' sig:', c%par%sig_dusts(i)
    call display_string_both(str_disp, a_book_keeping%fU, onlyfile=.true.)
  end do
  c%par%en_exchange_tot = 0D0
  !
  if (c%par%ndust_tot .le. 1D-100) then
    c%par%sigdust_ave = 0D0
  else
    c%par%sigdust_ave = c%par%sigdust_ave / c%par%ndust_tot
  end if
  !
  c%par%GrainRadius_CGS = sqrt(c%par%sigdust_ave / phy_Pi)
  !
  c%par%SitesPerGrain = 4D0 * c%par%sigdust_ave * SitesDensity_CGS
  !
  c%par%ratioDust2GasMass = c%par%mdust_tot / c%par%mgas_cell
  !
  c%par%ratioDust2HnucNum = c%par%ndust_tot / c%par%n_gas
  !
  c%par%dust_depletion = c%par%ratioDust2GasMass / phy_ratioDust2GasMass_ISM
  !
  if (c%par%ndust_tot .le. 1D-100) then
    c%par%abso_wei = 0D0
  else
    c%par%abso_wei = c%par%mdusts_cell / c%par%mdust_tot
  end if
  !
  write(str_disp, '(A, ES12.3, A, ES12.3, A, ES12.3)') &
    'nd_tot:', c%par%ndust_tot, ' sig_d_ave:', c%par%sigdust_ave, &
    ' r_d:', c%par%GrainRadius_CGS
  call display_string_both(str_disp, a_book_keeping%fU, onlyfile=.true.)
  !
  c%val(1) = c%par%n_gas
  !
  if (grid_config%use_data_file_input) then
    c%par%Tgas    = c%val(2)
    c%par%Tdust   = c%val(2)
  else
    c%par%Tgas    = 400D0 / (1D0 + c%par%rcen) * (1D0 + c%par%zcen)
    c%par%Tdust   = 0D0 ! instead of c%par%Tgas
  end if
  !
  c%par%pressure_thermal = 0D0
  c%par%gravity_z = 0D0
  c%par%gravity_acc_z = 0D0
  !
  ! Calculate the local velocity gradient, thermal velocity width, turbulent
  ! width, coherent length
  !
  call calc_local_dynamics(c, init=.true.)
  !
end subroutine disk_set_a_cell_params


subroutine calc_local_dynamics(c, init)
  type(type_cell), intent(inout) :: c
  logical, intent(in), optional :: init
  double precision R3
  logical is_init
  !
  if (present(init)) then
    is_init = init
  else
    is_init = .false.
  end if
  !
  c%par%velo_Kepler = &
    sqrt( &
      (phy_GravitationConst_CGS * a_star%mass * &
      phy_Msun_CGS) / (c%par%rcen * phy_AU2cm))
  c%par%omega_Kepler = c%par%velo_Kepler / (c%par%rcen * phy_AU2cm)
  c%par%velo_gradient = 0.5D0 * c%par%velo_Kepler / &
                        (c%par%rcen * phy_AU2cm)
  !
  if (c%par%Tgas .le. 0D0) then
    if (is_init) then
      ! Use a guess value for initialization
      c%par%sound_speed = sqrt(phy_kBoltzmann_CGS * 100D0 / &
            (phy_mProton_CGS * c%par%MeanMolWeight*2D0))
    else
      c%par%sound_speed = 0D0
    end if
  else
    c%par%sound_speed = sqrt(phy_kBoltzmann_CGS*c%par%Tgas / &
            (phy_mProton_CGS * c%par%MeanMolWeight*2D0))
  end if
  !
  c%par%velo_width_turb = c%par%sound_speed
  !
  c%par%coherent_length = c%par%velo_width_turb / c%par%velo_gradient
  !
  R3 = (sqrt((c%par%rcen)**2 + &
             (c%par%zcen)**2))**3
  c%par%gravity_z = &
      phy_GravitationConst_CGS * a_star%mass * phy_Msun_CGS * &
      (c%par%mgas_cell + &
       c%par%mdust_tot) * &
      (-c%par%zcen / R3 / (phy_AU2cm**2))
  !
  c%par%ion_charge = get_ion_charge(c)
  c%par%ambipolar_f = c%par%n_gas * c%par%ion_charge *  &
    beta_ion_neutral_colli / c%par%omega_Kepler
  !
  if (.not. a_disk%use_fixed_alpha_visc) then
    if (is_init) then
      c%par%alpha_viscosity = a_disk%base_alpha
    else
      c%par%alpha_viscosity = get_alpha_viscosity(c%par%ambipolar_f) * &
        a_disk%base_alpha
      if (isnan(c%par%alpha_viscosity)) then
        write(str_disp, '(4ES16.6)') c%par%alpha_viscosity, c%par%ambipolar_f, &
          c%par%ion_charge, c%par%omega_Kepler
        call display_string_both(str_disp, a_book_keeping%fU, onlyfile=.true.)
      end if
    end if
  end if
  !
  c%par%pressure_thermal = &
    c%par%n_gas * c%par%Tgas * phy_kBoltzmann_CGS * &
    (c%abundances(chem_idx_some_spe%i_HI) + &
     c%abundances(chem_idx_some_spe%i_H2))
end subroutine calc_local_dynamics


pure subroutine get_alpha_viscosity_alt(alpha, par, y, n, base_val)
  double precision, intent(out) :: alpha
  type(type_cell_rz_phy_basic), intent(inout) :: par
  integer, intent(in) :: n
  double precision, dimension(n), intent(in) :: y
  double precision, intent(in) :: base_val
  !
  par%ion_charge = get_ion_charge_y(y, n)
  !
  par%ambipolar_f = par%n_gas * par%ion_charge * &
    beta_ion_neutral_colli / par%omega_Kepler
  !
  alpha = base_val * get_alpha_viscosity(par%ambipolar_f)
end subroutine get_alpha_viscosity_alt


pure function get_ion_charge(c)
  double precision get_ion_charge
  type(type_cell), intent(in) :: c
  integer i
  integer, parameter :: iCharge = 1
  get_ion_charge = 0D0
  do i=1, chem_species%nSpecies
    if (chem_species%elements(iCharge, i) .gt. 0) then
      get_ion_charge = get_ion_charge + &
        dble(chem_species%elements(iCharge, i)) * c%abundances(i)
    end if
  end do
end function get_ion_charge


pure function get_ion_charge_y(y, n)
  double precision get_ion_charge_y
  integer, intent(in) :: n
  double precision, dimension(n), intent(in) :: y
  integer i
  integer, parameter :: iCharge = 1
  get_ion_charge_y = 0D0
  do i=1, chem_species%nSpecies
    if ((y(i) .ge. 1D-30) .and. (chem_species%elements(iCharge, i) .gt. 0)) then
      get_ion_charge_y = get_ion_charge_y + &
        dble(chem_species%elements(iCharge, i)) * y(i)
    end if
  end do
end function get_ion_charge_y


pure function get_alpha_viscosity(am)
  double precision get_alpha_viscosity
  double precision, intent(in) :: am
  double precision, parameter :: smallnum = 1D-20
  double precision tmp, tmp1, tmp2
  if (am .le. smallnum) then
    get_alpha_viscosity = 0D0
  else
    tmp = log(am)
    tmp1 = exp(-2.4D0 * tmp)
    tmp2 = exp(-0.3D0 * tmp)
    get_alpha_viscosity = &
      0.5D0 / sqrt(2500D0*tmp1 + (8D0*tmp2 + 1D0)**2)
  end if
end function get_alpha_viscosity


subroutine disk_set_gridcell_params
  integer i
  do i=1, leaves%nlen
    call disk_set_a_cell_params(leaves%list(i)%p, cell_params_ini)
  end do
end subroutine disk_set_gridcell_params


subroutine calc_dust_MRN_par(mrn)
  type(type_dust_MRN), intent(inout) :: mrn
  double precision tmp1, tmp2, norm
  double precision, parameter :: smallnum = 1D-6
  !
  tmp1 = exp((1D0 - mrn%n) * log(mrn%rmin)) ! = rmin**(1-n)
  tmp2 = exp((1D0 - mrn%n) * log(mrn%rmax)) ! = rmax**(1-n)
  if (abs(mrn%n - 1D0) .le. smallnum) then
    norm = log(mrn%rmax/mrn%rmin)
  else
    norm = (tmp2 - tmp1) / (1D0 - mrn%n)
  end if
  if (abs(mrn%n - 2D0) .le. smallnum) then
    mrn%rav = log(mrn%rmax/mrn%rmin) / norm
  else
    mrn%rav  = (tmp2 * mrn%rmax    - tmp1 * mrn%rmin) &
        / ((2D0 - mrn%n) * norm)
  end if
  if (abs(mrn%n - 3D0) .le. smallnum) then
    mrn%r2av = log(mrn%rmax/mrn%rmin) / norm
  else
    mrn%r2av = (tmp2 * mrn%rmax**2 - tmp1 * mrn%rmin**2) &
        / ((3D0 - mrn%n) * norm)
  end if
  if (abs(mrn%n - 4D0) .le. smallnum) then
    mrn%r3av = log(mrn%rmax/mrn%rmin) / norm
  else
    mrn%r3av = (tmp2 * mrn%rmax**3 - tmp1 * mrn%rmin**3) &
        / ((4D0 - mrn%n) * norm)
  end if
end subroutine calc_dust_MRN_par


subroutine save_chem_rates(i0)
  integer, intent(in) :: i0
  integer fU, k
  character(len=128) filename, dir
  ! Use namelist for output some logging infomation.
  ! Not very readable, but easy to implement.
  namelist /cell_par_log/ hc_params
  !
  write(filename, '("reac_rates_cell_", I4.4, ".dat")') i0
  dir = trim(combine_dir_filename(a_book_keeping%dir, 'rates_log/'))
  if (.NOT. dir_exist(dir)) then
    call my_mkdir(dir)
  end if
  call openFileSequentialWrite(fU, combine_dir_filename(dir, filename), &
       99999, getu=1)
  !
  write(fU, nml=cell_par_log)
  !
  do k=1, chem_net%nReactions
    write(fU, '(A135, ES16.4E4)') chem_reac_str%list(k), chem_net%rates(k)
  end do
  close(fU)
end subroutine save_chem_rates


subroutine save_post_config_params
  type(type_disk_basic_params) disk_params_tmp
  namelist /disk_params_log/ disk_params_tmp
  disk_params_tmp = a_disk
  if (FileUnitOpened(a_book_keeping%fU)) then
    write(a_book_keeping%fU, nml=disk_params_log)
    flush(a_book_keeping%fU)
  end if
end subroutine save_post_config_params


subroutine load_refine_check_species
  integer fU, i, i1, ios, n
  character(len=const_len_init_abun_file_row) str
  n = GetFileLen_comment_blank( &
      combine_dir_filename(a_disk_ana_params%analyse_points_inp_dir, &
        a_disk_iter_params%filename_list_check_refine), '!')
  allocate(idx_Species_check_refine(n), &
           thr_Species_check_refine(n))
  call openFileSequentialRead(fU, &
    combine_dir_filename(a_disk_ana_params%analyse_points_inp_dir, &
      a_disk_iter_params%filename_list_check_refine), 99, getu=1)
  i1 = 0
  do
    read(fU, FMT='(A)', IOSTAT=ios) str
    if (ios .NE. 0) then
      exit
    end if
    do i=1, chem_species%nSpecies
      if (trim(str(1:const_len_species_name)) .EQ. chem_species%names(i)) then
        i1 = i1 + 1
        idx_Species_check_refine(i1) = i
        read(str(const_len_species_name+1:const_len_init_abun_file_row), &
          '(F7.1)') thr_Species_check_refine(i1)
        exit
      end if
    end do
  end do
  close(fU)
  a_disk_iter_params%nSpecies_check_refine = i1
  write(str_disp, '("! Species used for checking refinement:")')
  call display_string_both(str_disp, a_book_keeping%fU)
  do i=1, a_disk_iter_params%nSpecies_check_refine
    write(str_disp, '("! ", A12, ES12.2)') &
      chem_species%names(idx_Species_check_refine(i)), &
      thr_Species_check_refine(i)
    call display_string_both(str_disp, a_book_keeping%fU)
  end do
end subroutine load_refine_check_species


subroutine do_refine
  integer i, n_refine
  a_disk_iter_params%ncell_refine = 0
  do i=1, leaves%nlen
    if (need_to_refine(leaves%list(i)%p, n_refine)) then
      a_disk_iter_params%ncell_refine = a_disk_iter_params%ncell_refine + 1
      write(str_disp, '("!", I4, A, 4ES12.2, " into ", I4, " parts.")') &
        a_disk_iter_params%ncell_refine, ' Refining ', &
        leaves%list(i)%p%xmin, leaves%list(i)%p%xmax, &
        leaves%list(i)%p%ymin, leaves%list(i)%p%ymax, n_refine
      call display_string_both(str_disp, a_book_keeping%fU)
      call refine_this_cell_vertical(leaves%list(i)%p, n_refine)
    end if
  end do
end subroutine do_refine


subroutine remake_index
  call get_number_of_leaves(root)
  leaves%nlen = root%nleaves
  call grid_make_leaves(root)
  call grid_make_neighbors
  call grid_make_surf_bott
end subroutine remake_index


function need_to_refine(c, n_refine)
  logical need_to_refine
  type(type_cell), target :: c
  integer, intent(out), optional :: n_refine
  integer i, i0, i1, j
  double precision val_max, val_min
  logical flag1, flag2
  flag1 = .false.
  flag2 = .false.
  if (present(n_refine)) then
    n_refine = 0
  end if
  if (c%par%dz .le. grid_config%smallest_cell_size) then
    need_to_refine = .false.
    return
  end if
  do i=1, c%above%n
    i0 = c%above%idx(i)
    !if (leaves%list(i0)%p%iIter .lt. c%iIter) then
    if (leaves%list(i0)%p%iIter .lt. 1) then
      cycle
    end if
    do j=1, a_disk_iter_params%nSpecies_check_refine
      i1 = idx_Species_check_refine(j)
      val_max = max(leaves%list(i0)%p%abundances(i1), c%abundances(i1))
      val_min = min(leaves%list(i0)%p%abundances(i1), c%abundances(i1))
      if (val_max .gt. thr_Species_check_refine(j)) then
        if (val_max / val_min .gt. a_disk_iter_params%threshold_ratio_refine) then
          flag1 = .true.
          if (present(n_refine)) then
            n_refine = max(n_refine, int(log10(val_max / val_min)) * 2)
          end if
        end if
      end if
    end do
  end do
  do i=1, c%below%n
    i0 = c%below%idx(i)
    !if (leaves%list(i0)%p%iIter .lt. c%iIter) then
    if (leaves%list(i0)%p%iIter .lt. 1) then
      cycle
    end if
    do j=1, a_disk_iter_params%nSpecies_check_refine
      i1 = idx_Species_check_refine(j)
      val_max = max(leaves%list(i0)%p%abundances(i1), c%abundances(i1))
      val_min = min(leaves%list(i0)%p%abundances(i1), c%abundances(i1))
      if (val_max .gt. thr_Species_check_refine(j)) then
        if (val_max / val_min .gt. a_disk_iter_params%threshold_ratio_refine) then
          flag2 = .true.
          if (present(n_refine)) then
            n_refine = max(n_refine, int(log10(val_max / val_min)) * 2)
          end if
        end if
      end if
    end do
  end do
  need_to_refine = flag1 .or. flag2
  return
end function need_to_refine


subroutine refine_this_cell_vertical(c, n)
  ! c is a working cell that needs to be refined.
  type(type_cell), target :: c
  double precision dy
  integer, intent(in), optional :: n
  integer i, ndivide
  !
  if (present(n)) then
    ndivide = n
  else
    ndivide = 3
  end if
  !
  if (ndivide .lt. 2) then
    return
  end if
  !
  c%nleaves = ndivide
  c%nChildren = ndivide
  call init_children(c, ndivide)
  !
  dy = (c%ymax - c%ymin) / dble(ndivide)
  !
  do i=1, c%nChildren
    associate(cc => c%children(i)%p)
      cc%xmin = c%xmin
      cc%xmax = c%xmax
      cc%ymin = c%ymin + dble(i-1) * dy
      cc%ymax = c%ymin + dble(i)   * dy
      !
      ! Re-interpolate density from the input data.
      call set_cell_par_preliminary(cc)
      cc%using = .true.
      cc%converged = .false.
      cc%nOffspring = 0
      cc%nChildren = 0
      cc%nleaves = 1
      !
      cc%iIter = c%iIter
      !
      call disk_set_a_cell_params(cc, c%par)
      cc%par%Tgas = c%par%Tgas
      !
      cc%h_c_rates = c%h_c_rates
      cc%abundances = c%abundances
      !cc%col_den = c%col_den
      !cc%col_den_acc = c%col_den_acc
    end associate
  end do
  ! Avoid numerical roundings
  c%children(1)%p%ymin       = c%ymin
  c%children(ndivide)%p%ymax = c%ymax
  do i=1, c%nChildren-1
    c%children(i)%p%ymax = c%children(i+1)%p%ymin
  end do
  !
  ! Deactivate c
  c%using = .false.
  c%converged = .false.
  !deallocate(c%par, c%h_c_rates, c%abundances, c%col_den, c%col_den_acc)
  !deallocate(c%inner%idx, c%inner%fra)
  !deallocate(c%outer%idx, c%outer%fra)
  !deallocate(c%above%idx, c%above%fra)
  !deallocate(c%below%idx, c%below%fra)
  !deallocate(c%around%idx, c%around%fra)
  !deallocate(c%inner, c%outer, c%above, c%below, c%around)
end subroutine refine_this_cell_vertical


subroutine load_ana_species_list
  integer fU, ios, i, n
  integer, dimension(:), allocatable :: list_tmp
  character(len=12) str
  if (.not. a_disk_ana_params%do_analyse) then
    return
  end if
  !
  call openFileSequentialRead(fU, &
       combine_dir_filename(a_disk_ana_params%analyse_points_inp_dir, &
         a_disk_ana_params%file_list_analyse_species), 99, getu=1)
  allocate(list_tmp(chem_species%nSpecies))
  n = 0
  do
    read(fU, '(A12)', iostat=ios) str
    if (ios .ne. 0) then
      exit
    end if
    do i=1, chem_species%nSpecies
      if (chem_species%names(i) .eq. str) then
        !
        if (.not. is_in_list_int(i, n, list_tmp(1:n))) then
          n = n + 1
          list_tmp(n) = i
        end if
        !
        exit
        !
      end if
    end do
  end do
  close(fU)
  !
  ana_splist%nlen = n
  if (n .gt. 0) then
    if (allocated(ana_splist%vals)) then
      deallocate(ana_splist%vals)
    end if
    allocate(ana_splist%vals(n))
    ana_splist%vals = list_tmp(1:n)
  end if
  deallocate(list_tmp)
end subroutine load_ana_species_list



subroutine load_ana_points_list
  integer fU, ios, i, n
  double precision r, z
  integer, dimension(:), allocatable :: list_tmp
  if (.not. a_disk_ana_params%do_analyse) then
    return
  end if
  !
  call openFileSequentialRead(fU, &
       combine_dir_filename(a_disk_ana_params%analyse_points_inp_dir, &
         a_disk_ana_params%file_list_analyse_points), 99, getu=1)
  allocate(list_tmp(leaves%nlen))
  n = 0
  do
    read(fU, '(2F6.2)', iostat=ios) r, z
    if (ios .ne. 0) then
      exit
    end if
    do i=1, leaves%nlen
      if ((leaves%list(i)%p%par%rmin .le. r) .and. (leaves%list(i)%p%par%rmax .ge. r) .and. &
          (leaves%list(i)%p%par%zmin .le. z) .and. (leaves%list(i)%p%par%zmax .ge. z)) then
        !
        if (.not. is_in_list_int(i, n, list_tmp(1:n))) then
          n = n + 1
          list_tmp(n) = i
        end if
        !
        exit
        !
      end if
    end do
  end do
  close(fU)
  !
  ana_ptlist%nlen = n
  if (n .gt. 0) then
    if (allocated(ana_ptlist%vals)) then
      deallocate(ana_ptlist%vals)
    end if
    allocate(ana_ptlist%vals(n))
    ana_ptlist%vals = list_tmp(1:n)
  end if
  deallocate(list_tmp)
end subroutine load_ana_points_list



subroutine chem_analyse(id)
  use quick_sort
  integer, intent(in) :: id
  integer i, j, k, i0, fU1, fU2, fU3
  double precision sum_prod, sum_dest, accum
  character(len=128) fname_pre
  character(len=32) FMTstryHistory
  double precision dy_y, dt_t
  double precision frac
  double precision, dimension(:,:), allocatable :: reacHeats
  double precision, dimension(:), allocatable :: tmp
  frac = 0.1D0
  !
  write(*, '(A/)') 'Doing some analysis... Might be very slow.'
  !
  allocate(reacHeats(2, chem_net%nReactions), tmp(chem_net%nReactions))
  !
  write(fname_pre, &
        '(I4.4, "_rz_", F0.6, "_", F0.6, "_iter_", I3.3)') &
        id, leaves%list(id)%p%xmin, leaves%list(id)%p%ymin, &
        leaves%list(id)%p%iIter
  call openFileSequentialWrite(fU3, &
    combine_dir_filename(a_disk_ana_params%analyse_out_dir, &
      'evol_'//trim(fname_pre)//'.dat'), 999999, getu=1)
  !
  write(FMTstryHistory, '("(", I4, "A14)")') chem_species%nSpecies + 2
  write(fU3, FMTstryHistory) '!Time_(yr)    ', chem_species%names, '  Tgas        '
  write(FMTstryHistory, '("(", I4, "ES14.4E4)")') chem_species%nSpecies + 2
  do i=1, chemsol_params%n_record_real
    write(fU3, FMTstryHistory) chemsol_stor%touts(i), chemsol_stor%record(:, i)
  end do
  close(fU3)
  !
  call openFileSequentialWrite(fU1, &
    combine_dir_filename(a_disk_ana_params%analyse_out_dir, &
      'ele_'//trim(fname_pre)//'.dat'), 999, getu=1)
  !
  call openFileSequentialWrite(fU2, &
    combine_dir_filename(a_disk_ana_params%analyse_out_dir, &
      'contri_'//trim(fname_pre)//'.dat'), 999, getu=1)
  !
  if (a_disk_ana_params%ana_i_incr .le. 0) then
    a_disk_ana_params%ana_i_incr = 1+chemsol_params%n_record_real/20
  end if
  !
  write(fU1, '(2F10.1, 3ES12.2, 2I5, 4ES16.6)') &
    chem_params%Tgas,  chem_params%Tdust, &
    chem_params%n_gas, &
    chem_params%Av_toStar, &
    chem_params%Av_toISM, &
    id, leaves%list(id)%p%iIter, &
    leaves%list(id)%p%xmin, leaves%list(id)%p%xmax, &
    leaves%list(id)%p%ymin, leaves%list(id)%p%ymax
  write(fU2, '(2F10.1, 3ES12.2, 2I5, 4ES16.6)') &
    chem_params%Tgas,  chem_params%Tdust, &
    chem_params%n_gas, &
    chem_params%Av_toStar, &
    chem_params%Av_toISM, &
    id, leaves%list(id)%p%iIter, &
    leaves%list(id)%p%xmin, leaves%list(id)%p%xmax, &
    leaves%list(id)%p%ymin, leaves%list(id)%p%ymax
  do k=1, chemsol_params%n_record_real, a_disk_ana_params%ana_i_incr
    !
    if (k .ge. 2) then
      dy_y = maxval( &
        abs((chemsol_stor%record(:, k) - chemsol_stor%record(:, k-1))) / &
        (chemsol_stor%record(:, k) + chemsol_stor%record(:, k-1) + 1D-15))
      dt_t = (chemsol_stor%touts(k) - chemsol_stor%touts(k-1)) / &
             (chemsol_stor%touts(k) + chemsol_stor%touts(k-1))
      if (dy_y .lt. frac * dt_t) then
        cycle
      end if
    end if
    !
    chemsol_stor%y = chemsol_stor%record(:, k)
    chem_params%Tgas = chemsol_stor%y(chemsol_params%NEQ)
    !
    write(fU1, '("Time = ", ES14.4)') chemsol_stor%touts(k)
    write(fU1, '("Tgas = ", ES14.4)') chemsol_stor%y(chem_species%nSpecies+1)
    !
    call chem_elemental_residence
    write(fU1, '(4X, "Total net charge: ", ES10.2)') &
        sum(chemsol_stor%y(1:chem_species%nSpecies) * dble(chem_species%elements(1,:)))
    write(fU1, '(4X, "Total free charge: ", ES10.2)') &
        sum(chemsol_stor%y(1:chem_species%nSpecies) * abs(dble(chem_species%elements(1,:)))) / 2D0
    do i=1, const_nElement
      write(fU1, '(4X, A8)') const_nameElements(i)
      do j=1, chem_ele_resi(i)%n_nonzero
        i0 = chem_ele_resi(i)%iSpecies(j)
        write(fU1, '(6X, A12, 3ES10.2)') chem_species%names(i0), chemsol_stor%y(i0), &
          chem_ele_resi(i)%ele_frac(j), chem_ele_resi(i)%ele_accu(j)
      end do
    end do
    !
    write(fU2, '("Time = ", ES14.4)') chemsol_stor%touts(k)
    !
    if (ana_splist%nlen .le. 0) then
      cycle
    end if
    call get_contribution_each
    do i=1, chem_species%nSpecies
      if (.not. is_in_list_int(i, ana_splist%nlen, ana_splist%vals)) then
        cycle
      end if
      write(fU2, '(A12, ES12.2)') chem_species%names(i), chemsol_stor%y(i)
      sum_prod = sum(chem_species%produ(i)%contri)
      sum_dest = sum(chem_species%destr(i)%contri)
      write(fU2, '(2X, A, 2X, ES12.2)') 'Production', sum_prod
      accum = 0D0
      do j=1, min(chem_species%produ(i)%nItem, 20)
        i0 = chem_species%produ(i)%list(j)
        accum = accum + chem_species%produ(i)%contri(j)
        write(fU2, '(4X, I4, 2ES12.2, F8.2, ES12.2, 2X, 6A12, ES12.2, 2F9.2, 2F8.1)') &
          j, chem_species%produ(i)%contri(j), accum, accum/sum_prod, chem_net%rates(i0), &
          chem_net%reac_names(1:2, i0), chem_net%prod_names(1:4, i0), &
          chem_net%ABC(1:3, i0), chem_net%T_range(1:2, i0)
        if (chem_species%produ(i)%contri(j) .le. &
            chem_species%produ(i)%contri(1) * 1D-6) then
          exit
        end if
      end do
      write(fU2, '(2X, A, 2X, ES12.2)') 'Destruction', sum_dest
      accum = 0D0
      do j=1, min(chem_species%destr(i)%nItem, 20)
        i0 = chem_species%destr(i)%list(j)
        accum = accum + chem_species%destr(i)%contri(j)
        write(fU2, '(4X, I4, 2ES12.2, F8.2, ES12.2, 2X, 6A12, ES12.2, 2F9.2, 2F8.1)') &
          j, chem_species%destr(i)%contri(j), accum, accum/sum_dest, chem_net%rates(i0), &
          chem_net%reac_names(1:2, i0), chem_net%prod_names(1:4, i0), &
          chem_net%ABC(1:3, i0), chem_net%T_range(1:2, i0)
        if (chem_species%destr(i)%contri(j) .le. &
            chem_species%destr(i)%contri(1) * 1D-6) then
          exit
        end if
      end do
    end do
    !
    write(fU2, '("Tgas = ", ES14.4)') chemsol_stor%y(chem_species%nSpecies+1)
    do i=1, chem_net%nReactions
      reacHeats(1, i) = dble(i)
    end do
    call  heating_chemical_termbyterm(chem_params%Tgas, chem_net%nReactions, tmp)
    reacHeats(2, :) = -abs(tmp)
    call quick_sort_array(reacHeats(:, :), 2, chem_net%nReactions, 1, (/2/))
    do i=1, min(chem_net%nReacWithHeat, 50)
        i0 = int(reacHeats(1, i))
        write(fU2, '(4X, I4, ES12.2, 2X, 6A12, ES12.2, 2F9.2, 2F8.1)') &
          i, tmp(i0), chem_net%reac_names(1:2, i0), chem_net%prod_names(1:4, i0), &
          chem_net%ABC(1:3, i0), chem_net%T_range(1:2, i0)
    end do
    !
  end do
  close(fU1)
  close(fU2)
end subroutine chem_analyse



function get_H2_form_rate(c, XgH, XH, ngas) result(r)
  ! dn(H2)/dt
  double precision r
  double precision, intent(in) :: c, XgH, XH, ngas
  if (chemsol_params%H2_form_use_moeq) then
    r = c * XgH * XH * ngas
  else
    if (chem_idx_some_spe%i_gH .gt. 0) then
      r = c * XgH * XgH * ngas
    else
      r = c * XH * ngas
    end if
  end if
end function get_H2_form_rate



subroutine post_disk_iteration
  integer i
  do i=1, leaves%nlen
    associate(c => leaves%list(i)%p)
      if (c%par%sound_speed**2 .ge. &
        (2D0 * phy_GravitationConst_CGS * a_star%mass * phy_Msun_CGS &
         / (c%par%rcen * phy_AU2cm))) then
        c%using = .false.
      end if
    end associate
  end do
end subroutine post_disk_iteration


end module disk



subroutine chem_ode_f(NEQ, t, y, ydot)
  use chemistry
  use heating_cooling
  implicit none
  integer NEQ, i, j, i1
  double precision t, y(NEQ), ydot(NEQ), rtmp, tmp
  ydot = 0D0
  !
  if (chemsol_params%evolT .and. (NEQ .ge. chem_species%nSpecies+1)) then
    if (y(chem_species%nSpecies+1) .ne. chem_params%Tgas) then
      chem_params%Tgas = y(chem_species%nSpecies+1)
      call chem_cal_rates
    end if
  end if
  !
  do i=1, chem_net%nReactions
    select case (chem_net%itype(i))
      case (5, 21, 64) ! A + B -> C ! 53
        rtmp = chem_net%rates(i) * y(chem_net%reac(1, i)) * y(chem_net%reac(2, i))
      case (1, 2, 3, 13, 61, 20) ! A -> B
        rtmp = chem_net%rates(i) * y(chem_net%reac(1, i))
      case (62)
        tmp = y(chem_net%reac(1, i)) / &
          (chem_params%ratioDust2HnucNum * chem_params%SitesPerGrain)
        if (tmp .le. 1D-9) then
          rtmp = chem_net%rates(i) * tmp
        else
          rtmp = chem_net%rates(i) * (1D0 - exp(-tmp))
        end if
      case (75)
        tmp = y(chem_net%reac(1, i)) / &
          (chem_params%ratioDust2HnucNum * chem_params%SitesPerGrain &
           * chem_net%ABC(3, i))
        if (tmp .le. 1D-9) then
          rtmp = chem_net%rates(i) * tmp
        else
          rtmp = chem_net%rates(i) * (1D0 - exp(-tmp))
        end if
      case (63) ! gA + gA -> gB
        ! dt(N(H2)) = k_HH * <H(H-1)>
        ! Moment equation:
        ! dt(N(H2)) = k_HH / (k_HH + k_desorb) * sigma * v * n(H) * N(gH)
        ! dt(X(H2)) = k_HH / (k_HH + k_desorb) * sigma * v * n(H) * X(gH)
        ! dt(X(H2)) = k_HH / (k_HH + k_desorb) * sigma * v * X(H) * X(gH) * n_dust / D2G
        ! Rate equation:
        ! dt(X(H2)) = k_HH * X(H)**2 / D2G
        if (chem_net%reac_names(1, i) .eq. 'gH') then
          if (chemsol_params%H2_form_use_moeq) then
            i1 = chem_species%idx_gasgrain_counterpart(chem_net%reac(1, i))
            rtmp = chem_net%rates(i) * y(i1) * y(chem_net%reac(1, i))
            ydot(i1) = ydot(i1) - rtmp ! It's like H + gH -> gH2. So dt(H) -= rtmp, dt(gH) += rtmp
            ydot(chem_net%reac(1, i)) = ydot(chem_net%reac(1, i)) + rtmp
          else
            rtmp = chem_net%rates(i) * y(chem_net%reac(1, i)) * y(chem_net%reac(1, i))
          end if
        else
          rtmp = chem_net%rates(i) * y(chem_net%reac(1, i)) * y(chem_net%reac(1, i))
        end if
      case (0)
        rtmp = chem_net%rates(i) * y(chem_net%reac(1, i))
      case default
        cycle
    end select
    !
    do j=1, chem_net%n_reac(i)
      ydot(chem_net%reac(j, i)) = ydot(chem_net%reac(j, i)) - rtmp
    end do
    do j=1, chem_net%n_prod(i)
      ydot(chem_net%prod(j, i)) = ydot(chem_net%prod(j, i)) + rtmp
    end do
  end do
  !
  if (chemsol_params%evolT .and. (NEQ .ge. chem_species%nSpecies+1)) then
    call realtime_heating_cooling_rate(ydot(chem_species%nSpecies+1), NEQ, y)
  else
    ydot(chem_species%nSpecies+1) = 0D0
  end if
  !
end subroutine chem_ode_f




subroutine realtime_heating_cooling_rate(r, NEQ, y)
  ! Heating/cooling rate for a single average gas particle.
  use chemistry
  use heating_cooling
  use disk
  double precision, intent(out) :: r
  integer, intent(in) :: NEQ
  double precision, dimension(NEQ), intent(in) :: y
  integer, parameter :: nitermax_dusts=16
  double precision rate_dg_exch0
  integer i, j
  !
  hc_params%Tgas    = y(chem_species%nSpecies+1)
  hc_params%X_H2    = y(chem_idx_some_spe%i_H2)
  hc_params%X_HI    = y(chem_idx_some_spe%i_HI)
  hc_params%X_CI    = y(chem_idx_some_spe%i_CI)
  hc_params%X_Cplus = y(chem_idx_some_spe%i_Cplus)
  hc_params%X_OI    = y(chem_idx_some_spe%i_OI)
  hc_params%X_CO    = y(chem_idx_some_spe%i_CO)
  hc_params%X_H2O   = y(chem_idx_some_spe%i_H2O)
  hc_params%X_OH    = y(chem_idx_some_spe%i_OH)
  hc_params%X_E     = y(chem_idx_some_spe%i_E)
  hc_params%X_Hplus = y(chem_idx_some_spe%i_Hplus)
  if (chem_idx_some_spe%i_gH .gt. 0) then
    hc_params%X_gH   = y(chem_idx_some_spe%i_gH)
    hc_params%X_gH2  = leaves%list(id)%p%abundances(chem_idx_some_spe%i_gH2)
  end if
  hc_params%R_H2_form_rate_coeff = chem_params%R_H2_form_rate_coeff
  hc_params%R_H2_form_rate = &
    get_H2_form_rate( &
      hc_params%R_H2_form_rate_coeff, &
      hc_params%X_gH, &
      hc_params%X_HI, &
      hc_params%n_gas)
  !
  hc_Tgas = y(chem_species%nSpecies+1)
  !
  if (a_disk%allow_gas_dust_en_exch .and. a_disk%Tdust_iter_tandem &
      .and. (.not. isnan(hc_Tgas))) then
    rate_dg_exch0 = 0D0
    !
    do i=1, nitermax_dusts
      ! Solve Tdusts
      !
      call update_en_exchange_with_dust(hc_params)
      !
      if (abs(rate_dg_exch0-hc_params%en_exchange_tot) .le. &
          1D-2*abs(rate_dg_exch0)) then
        exit
      end if
      rate_dg_exch0 = hc_params%en_exchange_tot
      !
      do j=1, dusts%n
        if (hc_params%n_dusts(j) .le. 1D-100) then
          cycle
        end if
        !
        if (isnan(hc_params%en_exchange(j))) then
          cycle
        end if
        !
        hc_params%Tdusts(j) = get_Tdust_from_LUT( &
            (hc_params%en_gains(j) + hc_params%en_exchange(j)) &
            / (4*phy_Pi*hc_params%mdusts_cell(j)), luts%list(j), i1)
        !if (hc_params%en_exchange(j) .lt. 0D0) then
        !  ! Dust is heating the gas, hence the dust temperature itself cannot
        !  ! drop below the gas temperature.
        !  hc_params%Tdusts(j) = max(hc_params%Tgas, hc_params%Tdusts(j))
        !end if
      end do
    end do
    !
    hc_params%Tdust = sum(hc_params%n_dusts * a_disk%dustcompo(:)%mrn%r2av * hc_params%Tdusts) / &
                      sum(hc_params%n_dusts * a_disk%dustcompo(:)%mrn%r2av)
    hc_params%Tdust = max(hc_params%Tdust, a_disk_iter_params%minimum_Tdust)
  end if
  !
  hc_Tdust = hc_params%Tdust
  !
  hc_params%grand_abundance = sum(y(1:chem_species%nSpecies))
  !
  call get_alpha_viscosity_alt(hc_params%alpha_viscosity, &
    hc_params, y, NEQ, a_disk%base_alpha)
  !
  r = &
    heating_minus_cooling() * phy_SecondsPerYear / &
    (hc_params%n_gas * phy_kBoltzmann_CGS)
  !call disp_h_c_rates
end subroutine realtime_heating_cooling_rate




subroutine chem_ode_jac(NEQ, t, y, j, ian, jan, pdj)
  use chemistry
  use heating_cooling
  use trivials
  implicit none
  double precision t, rtmp, tmp, tmp1
  double precision, dimension(NEQ) :: y, pdj
  double precision, dimension(:) :: ian, jan
  integer NEQ, i, j, k, i1
  double precision dT_dt_1, dT_dt_2, del_ratio, del_0, del_0_T, delta_y
  double precision, dimension(NEQ) :: ydot1, ydot2
  del_ratio = 1D-3
  del_0 = 1D-12
  del_0_T = 1D-2
  pdj = 0D0
  do i=1, chem_net%nReactions
    select case (chem_net%itype(i))
      case (5, 21, 64) ! A + B -> C
        if (j .EQ. chem_net%reac(1, i)) then
          if (chem_net%reac(1, i) .ne. chem_net%reac(2, i)) then
            rtmp = chem_net%rates(i) * y(chem_net%reac(2, i))
          else
            rtmp = 2D0 * chem_net%rates(i) * y(chem_net%reac(2, i))
          end if
        else if (j .EQ. chem_net%reac(2, i)) then
          if (chem_net%reac(1, i) .ne. chem_net%reac(2, i)) then
            rtmp = chem_net%rates(i) * y(chem_net%reac(1, i))
          else
            rtmp = 2D0 * chem_net%rates(i) * y(chem_net%reac(1, i))
          end if
        else
          rtmp = 0D0
        end if
      case (1, 2, 3, 13, 61, 20) ! A -> B
        if (j .ne. chem_net%reac(1, i)) then
          rtmp = 0D0
        else
          rtmp = chem_net%rates(i)
        end if
      case (62)
        if (j .ne. chem_net%reac(1, i)) then
          rtmp = 0D0
        else
          tmp1 = 1D0 / (chem_params%ratioDust2HnucNum * chem_params%SitesPerGrain)
          tmp = y(chem_net%reac(1, i)) * tmp1
          if (tmp .le. 1D-4) then
            rtmp = chem_net%rates(i) * tmp1
          else
            rtmp = chem_net%rates(i) * tmp1 * exp(-tmp)
          end if
        end if
      case (75)
        if (j .ne. chem_net%reac(1, i)) then
          rtmp = 0D0
        else
          tmp1 = 1D0 / (chem_params%ratioDust2HnucNum * chem_params%SitesPerGrain &
                 * chem_net%ABC(3, i))
          tmp = y(chem_net%reac(1, i)) * tmp1
          if (tmp .le. 1D-4) then
            rtmp = chem_net%rates(i) * tmp1
          else
            rtmp = chem_net%rates(i) * tmp1 * exp(-tmp)
          end if
        end if
      case (63) ! gA + gA -> gB
        if (chem_net%reac_names(1, i) .eq. 'gH') then
          if (chemsol_params%H2_form_use_moeq) then
            i1 = chem_species%idx_gasgrain_counterpart(chem_net%reac(1, i))
            if (j .eq. chem_net%reac(1, i)) then
              rtmp = chem_net%rates(i) * y(i1)
              pdj(i1) = pdj(i1) - rtmp
              pdj(chem_net%reac(1, i)) = pdj(chem_net%reac(1, i)) + rtmp
            else if (j .eq. i1) then
              rtmp = chem_net%rates(i) * y(chem_net%reac(1, i))
              pdj(i1) = pdj(i1) - rtmp
              pdj(chem_net%reac(1, i)) = pdj(chem_net%reac(1, i)) + rtmp
            else
              rtmp = 0D0
            end if
          else
            if (j .eq. chem_net%reac(1, i)) then
              rtmp = 2D0 * chem_net%rates(i) * y(chem_net%reac(1, i))
            else
              rtmp = 0D0
            end if
          end if
        else
          if (j .eq. chem_net%reac(1, i)) then
            rtmp = 2D0 * chem_net%rates(i) * y(chem_net%reac(1, i))
          else
            rtmp = 0D0
          end if
        end if
      case (0)
        if (j .ne. chem_net%reac(1, i)) then
          rtmp = 0D0
        else
          rtmp = chem_net%rates(i)
        end if
      case default
        cycle
    end select
    !
    if (rtmp .NE. 0D0) then
      do k=1, chem_net%n_reac(i)
        pdj(chem_net%reac(k, i)) = pdj(chem_net%reac(k, i)) - rtmp
      end do
      do k=1, chem_net%n_prod(i)
        pdj(chem_net%prod(k, i)) = pdj(chem_net%prod(k, i)) + rtmp
      end do
    end if
  end do
  !
  if (chemsol_params%evolT .and. (NEQ .ge. chem_species%nSpecies+1)) then
    if (is_in_list_int(j, chem_idx_some_spe%nItem, chem_idx_some_spe%idx)) then
      if (y(j) .ge. 0D0) then
        call realtime_heating_cooling_rate(dT_dt_1, NEQ, y)
        delta_y = y(j) * del_ratio + del_0
        rtmp = y(j)
        y(j) = y(j) + delta_y
        call realtime_heating_cooling_rate(dT_dt_2, NEQ, y)
        pdj(chem_species%nSpecies+1) = (dT_dt_2 - dT_dt_1) / delta_y
        y(j) = rtmp
      else
        pdj(chem_species%nSpecies+1) = 0D0
      end if
    else if (j .eq. (chem_species%nSpecies+1)) then
      call chem_ode_f(NEQ, t, y, ydot1)
      delta_y = y(j) * del_ratio + del_0_T
      rtmp = y(j)
      y(j) = y(j) + delta_y
      call chem_ode_f(NEQ, t, y, ydot2)
      pdj = (ydot2 - ydot1) / delta_y
      y(j) = rtmp
      chem_params%Tgas = rtmp
    end if
  else
    pdj(chem_species%nSpecies+1) = 0D0
  end if
end subroutine chem_ode_jac
