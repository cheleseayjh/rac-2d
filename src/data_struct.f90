module data_struct

implicit none

integer, parameter :: MaxNumOfGasComponents  = 1
integer, parameter :: MaxNumOfDustComponents = 4

integer, parameter, private :: const_len_energy_level = 12
integer, parameter, private :: const_len_molecule = 12

integer, parameter :: LongInt = 8

type :: type_ray
  double precision x, y, z, vx, vy, vz
end type type_ray


type :: type_photon_packet
  ! Mainly for Monte Carlo.
  type(type_ray) :: ray
  double precision lam, en
  double precision f, Inu
  integer iKap, iSpec
  integer e_count
end type type_photon_packet


type :: type_photon_ray_multi
  ! Mainly for ray-tracing (to make image and spectra)
  type(type_ray) :: ray
  integer iTran, nf
  double precision, dimension(:), allocatable :: lam, f, Inu
  integer, dimension(:), allocatable :: iKap
end type type_photon_ray_multi


type :: type_position_cartesian
  double precision x, y, z
end type type_position_cartesian



type :: type_direction_cartesian
  double precision u, v, w
end type type_direction_cartesian


type :: type_sphere_coor_quat
  double precision costheta, sintheta, cosphi, sinphi
end type type_sphere_coor_quat


type :: type_photon_collector
  ! Use mu = cos(theta) instead of theta to save some calculations.
  integer nlam, iKap0, iKap1, nmu, nr, nphi
  double precision, dimension(:), allocatable :: &
    mu_min, mu_max, r_min, r_max, phi_min, phi_max
  double precision, dimension(:,:,:,:), allocatable :: energy
  integer, dimension(:,:,:,:), allocatable :: counts
end type type_photon_collector


type :: type_spectrum_generic
  integer n
  double precision, dimension(:,:), allocatable :: intervals
  double precision, dimension(:), allocatable :: vals
end type type_spectrum_generic


type :: type_distribution_table
  integer n
  double precision, dimension(:), allocatable :: pvals
end type type_distribution_table


type :: type_simple_integer_list
  integer :: nlen = 0
  integer, dimension(:), allocatable :: vals
end type type_simple_integer_list


type :: type_optical_property
  integer n
  double precision, dimension(:), allocatable :: lam
  double precision, dimension(:), allocatable :: ab, sc, g
end type type_optical_property


type :: type_global_material_collection
  integer ntype
  type(type_optical_property), dimension(:), allocatable :: list
  double precision, dimension(:), allocatable :: &
                              Xray_gas_abs, &
                              Xray_gas_sca, &
                              Xray_dus_abs, &
                              Xray_dus_sca
end type type_global_material_collection


type :: type_local_encounter_collection
  integer ntype, nlam
  integer cr_count
  double precision, dimension(:), allocatable :: X
  double precision, dimension(:), allocatable :: summed_ab, summed_sc
  double precision, dimension(:), allocatable :: summed
  double precision, dimension(:,:), allocatable :: acc
  double precision, dimension(:), allocatable :: flux
  integer, dimension(:), allocatable :: phc
  type(type_direction_cartesian), dimension(:), allocatable :: dir_wei
end type type_local_encounter_collection


type :: type_LUT_Tdust
  ! A look-up table
  ! Given a val, find out the corresponding T
  integer n, m
  double precision, dimension(:), allocatable :: Tds, vals
  double precision, dimension(:,:), allocatable :: table
end type type_LUT_Tdust


type :: type_continuum_lut
  integer :: n=0
  double precision, dimension(:), allocatable :: lam, alpha, J
end type type_continuum_lut


type :: type_stellar_params
  integer n
  double precision mass, radius, T, &
    lumi, lumi_Vis, lumi_UV, lumi_Lya, lumi0, lumi_UV0
  double precision :: T_Xray=1D7, E0_Xray=0.1D0, E1_Xray=10D0, lumi_Xray=1D30
  double precision, dimension(:), allocatable :: lam, vals, vals0
end type type_stellar_params



type :: type_montecarlo_config
  double precision eph
  integer(kind=LongInt) nph, icount, nmax_cross, nmax_encounter
  character(len=128) fname_photons, fname_dust, fname_water, fname_star, fname_save_collected
  character(len=128) mc_dir_in, mc_dir_out
  double precision minw, maxw
  double precision :: starpos_r=0D0, starpos_z = 0D0
  logical :: use_blackbody_star=.true. !, savephoton=.false.
  logical :: ph_init_symmetric=.false.
  double precision :: refine_UV = 0.01D0, refine_LyA = 0.001D0, refine_Xray = 1D-4
  logical :: collect_photon=.false.
  double precision dist
  double precision :: collect_lam_min=1D0, collect_lam_max=1D6
  double precision :: collect_dmu=0.1D0
  integer :: collect_nmu=3, collect_nr=50, collect_nphi=50
  double precision, dimension(8) :: collect_ang_mins, collect_ang_maxs
  integer :: nlen_lut=1024
  double precision :: TdustMin=1D0, TdustMax=2D3
end type type_montecarlo_config


type :: type_energy_level
  character(len=const_len_energy_level) :: name_energy
  integer id
  double precision :: energy
  double precision :: weight
end type type_energy_level


type :: type_rad_transition
  double precision Eup, Elow, dE, freq, lambda
  double precision Aul, Bul, Blu, beta, J_ave, cooling_rate
  integer iup, ilow
end type type_rad_transition


type :: type_collisional_transition
  character(len=const_len_molecule) :: name_partner
  double precision dens_partner
  integer n_transition, n_T
  integer, dimension(:), allocatable :: iup, ilow
  double precision, dimension(:), allocatable :: T_coll
  double precision, dimension(:,:), allocatable :: Cul
end type type_collisional_transition


type :: type_rad_set
  integer n_transition
  type(type_rad_transition), dimension(:), allocatable :: list
end type type_rad_set


type :: type_colli_set
  integer n_partner
  type(type_collisional_transition), dimension(:), allocatable :: list
end type type_colli_set


type :: type_molecule_energy_set
  character(len=const_len_molecule) name_molecule
  integer iSpe, iType
  double precision Tkin, density_mol, dv, length_scale, cooling_rate_total
  integer n_level
  type(type_energy_level), dimension(:), allocatable :: level_list
  double precision, dimension(:), allocatable :: f_occupation
  type(type_rad_set), allocatable :: rad_data
  type(type_colli_set), allocatable :: colli_data
  double precision :: abundance_factor = 1D0
end type type_molecule_energy_set


type :: type_statistic_equil_params
  integer nitem
  double precision :: RTOL = 1D-3, ATOL = 1D-15
  double precision :: t_max = 1D10, dt_first_step = 1D-6, ratio_tstep = 1.2D0
  real :: max_runtime_allowed = 5.0
  integer n_record
  integer :: &
        NERR, &
        NEQ, &
        ITOL = 1, &
        ITASK = 1, &
        ISTATE = 1, &
        IOPT = 1, &
        LIW, &
        LRW, &
        MF = 21
  double precision, dimension(:), allocatable :: RWORK
  integer, dimension(:), allocatable :: IWORK
  logical is_good
end type type_statistic_equil_params

type :: type_mole_f_occ
  integer nlevels
  double precision, dimension(:), allocatable :: vals
end type type_mole_f_occ


type :: type_mole_exc_conf
  character(len=128) :: dirname_mol_data=''
  character(len=128) :: fname_mol_data=''
  character(len=16) :: mole_name=''
  character(len=128) :: dir_save_image=''
  character(len=8) :: line_database='lamda'
  integer nfreq_window
  double precision, dimension(10) :: freq_mins, freq_maxs
  integer nlam_window
  double precision, dimension(10) :: lam_mins, lam_maxs
  double precision abundance_factor
  double precision :: E_min = 0D0, E_max = 5D3
  double precision :: min_flux=0D0
  double precision :: VeloHalfWidth
  logical :: useLTE = .true.
  logical :: save_spectrum_only = .false.
  !
  double precision :: maxx=0D0, maxy=0D0
  integer nf, nlam, nth, nx, ny
  double precision dist
  double precision, dimension(16) :: view_thetas
  !
end type type_mole_exc_conf


type :: type_molecule_exc
  type(type_mole_exc_conf) :: conf
  type(type_molecule_energy_set), pointer :: p => null()
  integer nlevel_keep, ntran_keep
  integer, dimension(:), allocatable :: ilv_keep, ilv_reverse
  integer, dimension(:), allocatable :: itr_keep, itr_reverse
end type type_molecule_exc


type :: type_fits_par
  character(len=256) :: filename
  integer stat, fU, blocksize, bitpix, naxis
  integer, dimension(3) :: naxes
  integer i, j, group, fpixel, nelements, decimals
  integer pcount, gcount
  logical simple, extend
  character(len=32) :: extname
  character(len=32) :: author, user
end type type_fits_par


type :: type_cell_rz_phy_basic
  integer(kind=LongInt) ab_count_dust, ab_count_water, &
                        sc_count_dust, sc_count_HI
  !
  integer ndustcompo
  !
  double precision :: &
    rmin, rmax, rcen, dr, zmin, zmax, zcen, dz, &
    volume, surf_area, area_T, area_B, area_I, area_O, &
    Tgas, &
    Tdust, &
    grand_gas_abundance, &
    !
    n_gas, &
    !
    mgas_cell, &
    !
    Tdusts(MaxNumOfDustComponents), &
    rho_dusts(MaxNumOfDustComponents), &
    n_dusts(MaxNumOfDustComponents), &
    mp_dusts(MaxNumOfDustComponents), &
    mdusts_cell(MaxNumOfDustComponents), &
    !
    en_exchange_per_vol(MaxNumOfDustComponents), &
    en_exchange(MaxNumOfDustComponents), &
    en_exchange_tot, &
    !
    abso_wei(MaxNumOfDustComponents), &
    !
    sig_dusts(MaxNumOfDustComponents), &
    en_gains(MaxNumOfDustComponents), &
    en_gains_abso(MaxNumOfDustComponents), &
    en_prevs(MaxNumOfDustComponents), &
    kphs(MaxNumOfDustComponents), &
    !
    en_gain_tot, &
    en_gain_abso_tot, &
    !
    sigdust_ave, &
    ndust_tot, &
    mdust_tot, &
    !
    UV_G0_factor_background, &
    !
    ab_en_water, &
    !
    phflux_Lya, &
    !
    flux_UV_star_unatten, &
    flux_Lya_star_unatten, &
    flux_Vis_star_unatten, &
    !
    G0_UV_toISM, &
    G0_UV_toStar, &
    G0_Lya_atten, &
    !
    Av_toISM, &
    Av_toStar, &
    !
    Ncol_toISM, &
    Ncol_toStar, &
    !
    omega_albedo, &
    zeta_cosmicray_H2, &
    !
    zeta_Xray_H2, &
    !
    R_H2_form_rate_coeff, &
    R_H2_form_rate, &
    !
    f_selfshielding_toISM_H2, &
    f_selfshielding_toISM_CO, &
    f_selfshielding_toISM_H2O, &
    f_selfshielding_toISM_OH, &
    !
    f_selfshielding_toStar_H2, &
    f_selfshielding_toStar_CO, &
    f_selfshielding_toStar_H2O, &
    f_selfshielding_toStar_OH, &
    !
    SitesPerGrain, &
    GrainMaterialDensity_CGS, &
    GrainRadius_CGS, &
    !
    ratioDust2GasMass, &
    ratioDust2HnucNum, &
    dust_depletion, &
    MeanMolWeight, &
    !
    omega_Kepler, &
    velo_Kepler, &
    velo_gradient, &
    velo_width_turb, &
    coherent_length, &
    sound_speed, &
    !
    alpha_viscosity, &
    ambipolar_f, &
    ion_charge, &
    Neufeld_G, &
    Neufeld_dv_dz, &
    !
    t_final, &
    !
    X_H2, X_HI, X_CI, X_Cplus, X_OI, X_CO, &
    X_H2O, X_OH, X_E, X_Hplus, X_gH, X_gH2, &
    flux_tot, flux_Xray, flux_UV, flux_Lya, &
    flux_Vis, flux_NIR, flux_MIR, flux_FIR, &
    dir_tot_r, dir_tot_z, dir_Xray_r, dir_Xray_z, &
    dir_UV_r,  dir_UV_z,  dir_Lya_r, dir_Lya_z, &
    dir_Vis_r, dir_Vis_z, dir_NIR_r, dir_NIR_z, &
    dir_MIR_r, dir_MIR_z, dir_FIR_r, dir_FIR_z, &
    aniso_tot, aniso_Xray, aniso_UV, aniso_Lya, &
    aniso_Vis, aniso_NIR, aniso_MIR, aniso_FIR, &
    !
    pressure_thermal, gravity_z, gravity_acc_z
  !
  !
end type type_cell_rz_phy_basic


type :: type_dust_MRN
  double precision :: rmin, rmax, n
  double precision :: rav, r2av, r3av
end type type_dust_MRN


type :: type_Andrews_disk
  logical :: useNumDens = .true.
  double precision :: particlemass = 1.4D0 * 1.67262158D-24
  double precision :: Md=0.00D0 ! Disk mass in Msun
  double precision :: rin=0.5D0, rout=200D0
  double precision :: rc=200D0  ! Disk outer boundary
  double precision :: hc=50D0   ! Scale height at outer boundary
  double precision :: gam=1D0   ! Power index for surface density
  double precision :: psi=1D0   ! Power index for scale height
  !
  double precision :: r0_in_exp = 0D0 ! Exponential taper inward this radius
  double precision :: rs_in_exp = 1D5 ! Scale length of the exponential taper
  double precision :: r0_out_exp = 1D5 ! Exponential taper outward this radius
  double precision :: rs_out_exp = 1D5 ! Scale length of the exponential taper
  !
  double precision :: r0_in_change = 0D0 ! Change vertical scale inward this radius
  double precision :: f_in_change = 1D0 ! Factor of vertical scale change
  double precision :: r0_out_change = 1D5 ! Change vertical scale outward this radius
  double precision :: f_out_change = 1D0 ! Factor of vertical scale change
  !
end type type_Andrews_disk


type :: type_a_dust_component
  integer itype
  double precision pmass_CGS
  type(type_dust_MRN) :: mrn
  type(type_Andrews_disk) :: andrews
end type type_a_dust_component


type :: type_heating_cooling_rates_list
  double precision :: &
    hc_net_rate = 0D0, &
    heating_photoelectric_small_grain_rate = 0D0, &
    heating_formation_H2_rate = 0D0, &
    heating_cosmic_ray_rate = 0D0, &
    heating_vibrational_H2_rate = 0D0, &
    heating_ionization_CI_rate = 0D0, &
    heating_photodissociation_H2_rate = 0D0, &
    heating_photodissociation_H2O_rate = 0D0, &
    heating_photodissociation_OH_rate = 0D0, &
    heating_Xray_Bethell_rate = 0D0, &
    heating_viscosity_rate = 0D0, &
    heating_chem = 0D0, &
    cooling_photoelectric_small_grain_rate = 0D0, &
    cooling_vibrational_H2_rate = 0D0, &
    cooling_gas_grain_collision_rate = 0D0, &
    cooling_OI_rate = 0D0, &
    cooling_CII_rate = 0D0, &
    cooling_Neufeld_H2O_rate_rot = 0D0, &
    cooling_Neufeld_H2O_rate_vib = 0D0, &
    cooling_Neufeld_CO_rate_rot = 0D0, &
    cooling_Neufeld_CO_rate_vib = 0D0, &
    cooling_Neufeld_H2_rot_rate = 0D0, &
    cooling_LymanAlpha_rate = 0D0, &
    cooling_free_bound_rate = 0D0, &
    cooling_free_free_rate = 0D0
end type type_heating_cooling_rates_list


type, private :: type_child_container
  type(type_cell), pointer :: p
end type type_child_container


type :: type_neighbor
  integer :: n = 0
  integer, dimension(:), allocatable :: idx
  double precision, dimension(:), allocatable :: fra
  double precision :: fra_tot = 0D0
end type type_neighbor


type :: type_cell
  double precision :: xmin=0D0, xmax=0D0, ymin=0D0, ymax=0D0
  double precision, dimension(:), allocatable :: val
  logical :: using = .false., converged = .false.
  integer :: id = -1
  integer :: order=0, nChildren=0, nOffspring=0, nleaves=0
  type(type_cell), pointer :: parent => null()
  type(type_child_container), pointer, dimension(:) :: children
  type(type_neighbor), pointer :: &
        inner => null(), outer => null(), &
        below => null(), above => null(), &
        around => null()
  type(type_cell_rz_phy_basic), pointer :: par => null()
  type(type_heating_cooling_rates_list), allocatable :: h_c_rates
  double precision, dimension(:), allocatable :: abundances
  double precision, dimension(:), allocatable :: col_den_toStar, col_den_toISM
  integer :: iIter = 0
  integer :: quality = 0
  type(type_local_encounter_collection) :: optical
  type(type_mole_f_occ), allocatable :: focc
  type(type_continuum_lut), allocatable :: cont_lut
end type type_cell


end module data_struct

