!> @author Ali Samii - 2016
!! Ali Samii - Department of ASE/EM, UT Austin
!! @brief This module is an interface between parallel Adcirc input files and ESMF library.
module ADCIRC_interpolation

    use ESMF
    use MPI

    !> \author Ali Samii - 2016
    !! \brief This object stores the data required for construction of a parallel or serial
    !! ESMF_Mesh from <tt>fort.14, fort.18, partmesh.txt</tt> files.
    !!
    type meshdata
        !> \details vm is an ESMF_VM object.  ESMF_VM is just an ESMF virtual machine class,
        !! which we will use to get the data about the local PE and PE count.
        type(ESMF_VM)                      :: vm
        !> \details This array contains the node coordinates of the mesh. For
        !! example, in a 2D mesh, the \c jth coordinate of the \c nth node
        !! is stored in location <tt> 2*(n-1)+j</tt> of this array.
        real(ESMF_KIND_R8), allocatable    :: NdCoords(:)
        !> \details This array contains the elevation of different nodes of the mesh
        real(ESMF_KIND_R8), allocatable    :: bathymetry(:)
        !> \details Number of nodes present in the current PE. This is different from the
        !! number of nodes owned by this PE (cf. NumOwnedNd)
        integer(ESMF_KIND_I4)              :: NumNd
        !> \details Number of nodes owned by this PE. This is different from the number of
        !! nodes present in the current PE (cf. NumNd)
        integer(ESMF_KIND_I4)              :: NumOwnedNd
        !> \details Number of elements in the current PE. This includes ghost elements and
        !! owned elements. However, we do not bother to distinguish between owned
        !! element and present element (as we did for the nodes).
        integer(ESMF_KIND_I4)              :: NumEl
        !> \details Number of nodes of each element, which is simply three in 2D ADCIRC.
        integer(ESMF_KIND_I4)              :: NumND_per_El
        !> \details Global node numbers of the nodes which are present in the current PE.
        integer(ESMF_KIND_I4), allocatable :: NdIDs(:)
        !> \details Global element numbers which are present in the current PE.
        integer(ESMF_KIND_I4), allocatable :: ElIDs(:)
        !> \details The element connectivity array, for the present elements in the current PE.
        !! The node numbers are the local numbers of the present nodes. All the element
        !! connectivities are arranged in this one-dimensional array.
        integer(ESMF_KIND_I4), allocatable :: ElConnect(:)
        !> \details The number of the PE's which own each of the nodes present this PE.
        !! This number is zero-based.
        integer(ESMF_KIND_I4), allocatable :: NdOwners(:)
        !> \details An array containing the element types, which are all triangles in our
        !! application.
        integer(ESMF_KIND_I4), allocatable :: ElTypes(:)
        !> \details This is an array, which maps the indices of the owned nodes to the indices of the present
        !! nodes. For example, assume we are on <tt>PE = 1</tt>, and we have four nodes present, and the
        !! first and third nodes belong to <tt>PE = 0</tt>. So we have:
        !! \code
        !! NumNd = 4
        !! NumOwnedNd = 2
        !! NdOwners = (/0, 1, 0, 1/)
        !! NdIDs = (/2, 3, 5, 6/)
        !! owned_to_present = (/2, 4/)    <-- Because the first node owned by this PE is actually
        !!                                    the second node present on this PE, and so on.
        !! \endcode
        integer(ESMF_KIND_I4), allocatable :: owned_to_present_nodes(:)
    end type meshdata

    !>
    !! \author Ali Samii - 2016
    !! This structure stores the data from an ADCIRC hotstart file. To know more about
    !! different members of this stucture, consult ADCIRC manual or user refernce.
    type hotdata
        real(kind=8)                 :: TimeLoc
        real(kind=8), allocatable    :: ETA1(:), ETA2(:), ETADisc(:), UU2(:), VV2(:), CH1(:)
        integer, allocatable         :: NNODECODE(:), NOFF(:)
        integer                      :: InputFileFmtVn, IMHS, ITHS, NP_G_IN, NE_G_IN, NP_A_IN, NE_A_IN, &
                                        IESTP, NSCOUE, IVSTP, NSCOUV, ICSTP, NSCOUC, IPSTP, IWSTP, NSCOUM, IGEP, NSCOUGE, IGVP, &
                                        NSCOUGV, IGCP, NSCOUGC, IGPP, IGWP, NSCOUGW
    end type

    !>
    !!
    !!
    type regrid_data
        real(ESMF_KIND_R8), pointer     :: src_fieldptr(:), mapped_fieldptr(:), unmapped_fieldptr(:), dst_maskptr(:)
        type(ESMF_Field)                :: src_datafield, dst_mask_field, dst_mapped_field, dst_unmapped_field
        type(ESMF_RouteHandle)          :: mapped_route_handle, unmapped_route_handle
    end type

contains

    !> \details As the name of this function suggests, this funciton creates a parallel
    !! ESMF_Mesh from meshdata object. This function should be called collectively by
    !! all PEs for the parallel mesh to be created. The function, extract_parallel_data_from_mesh()
    !! should be called prior to calling this function.
    !! \param the_data This the input meshdata object.
    !! \param out_esmf_mesh This is the ouput ESMF_Mesh object.
    subroutine create_parallel_esmf_mesh_from_meshdata(the_data, out_esmf_mesh)
        implicit none
        type(ESMF_Mesh), intent(out)                  :: out_esmf_mesh
        type(meshdata), intent(in)                    :: the_data
        integer, parameter                            :: dim1=2, spacedim=2, NumND_per_El=3
        integer                                       :: rc
        out_esmf_mesh=ESMF_MeshCreate(parametricDim=dim1, spatialDim=spacedim, &
            nodeIDs=the_data%NdIDs, nodeCoords=the_data%NdCoords, &
            nodeOwners=the_data%NdOwners, elementIDs=the_data%ElIDs, &
            elementTypes=the_data%ElTypes, elementConn=the_data%ElConnect, &
            rc=rc)
    end subroutine

    !> \details This function is similar to create_parallel_esmf_mesh_from_meshdata(), except that
    !! it creates a masked mesh. A masked mesh is used for example to exclude the interpolation onto
    !! some nodes, when using ESMF interpolation routines.
    !! \param in_meshdata This is the input meshdata object.
    !! \param mask_array This is an array of length NumNd (number of present nodes on this PE)
    !! which contains integer numbers. When we plan to exclude a group of nodes from interpolation,
    !! we use these mask values in the interpolation routines.
    !! \param out_masked_mesh This is the output masked ESMF_Mesh.
    subroutine create_masked_esmf_mesh_from_data(in_meshdata, mask_array, out_maked_esmf_mesh)
        implicit none
        type(ESMF_Mesh), intent(out)       :: out_maked_esmf_mesh
        type(meshdata), intent(in)         :: in_meshdata
        integer(ESMF_KIND_I4), intent(in)  :: mask_array(:)
        integer, parameter                 :: dim1=2, spacedim=2, NumND_per_El=3
        integer                            :: rc
        out_maked_esmf_mesh=ESMF_MeshCreate(parametricDim=dim1, spatialDim=spacedim, &
            nodeIDs=in_meshdata%NdIDs, nodeCoords=in_meshdata%NdCoords, &
            nodeOwners=in_meshdata%NdOwners, elementIDs=in_meshdata%ElIDs, &
            elementTypes=in_meshdata%ElTypes, elementConn=in_meshdata%ElConnect, &
            nodeMask=mask_array, rc=rc)
        !print *, "mesh with mask creation: ", rc
    end subroutine create_masked_esmf_mesh_from_data

    !> @details Using the data available in <tt> fort.14, fort.18, partmesh.txt</tt> files
    !! this function extracts the scalars and arrays required for construction of a
    !! meshdata object.
    !! After calling this fucntion, one can call create_parallel_esmf_mesh_from_meshdata()
    !! or create_masked_esmf_mesh_from_data() to create an ESMF_Mesh.
    !! @param vm This is an ESMF_VM object, which will be used to obtain the \c localPE
    !! and \c peCount of the \c MPI_Communicator.
    !! @param global_fort14_dir This is the directory path (relative to the executable
    !! or an absolute path) which contains the global \c fort.14 file (not the fort.14
    !! after decomposition).
    !! @param the_data This is the output meshdata object.
    !!
    subroutine extract_parallel_data_from_mesh(vm, global_fort14_dir, the_data)
        implicit none
        type(ESMF_VM), intent(in)             :: vm
        type(meshdata), intent(inout)         :: the_data
        character(len=*), intent(in)          :: global_fort14_dir
        character(len=6)                      :: PE_ID, garbage1
        character(len=200)                    :: fort14_filename, fort18_filename, partmesh_filename
        integer                               :: i1, j1, i_num, localPet, petCount, num_global_nodes, garbage2, garbage3
        integer, allocatable                  :: local_node_numbers(:), local_elem_numbers(:), node_owner(:)
        integer, parameter                    :: dim1=2, NumND_per_El=3

        the_data%vm = vm
        call ESMF_VMGet(vm=vm, localPet=localPet, petCount=petCount)
        write(PE_ID, "(A,I4.4)") "PE", localPet
        fort14_filename = trim(global_fort14_dir//PE_ID//"/fort.14")
        fort18_filename = trim(global_fort14_dir//PE_ID//"/fort.18")
        partmesh_filename = trim(global_fort14_dir//"/partmesh.txt")

        open(unit=14, file=fort14_filename, form='FORMATTED', status='OLD', action='READ')
        open(unit=18, file=fort18_filename, form='FORMATTED', status='OLD', action='READ')
        open(unit=100, file=partmesh_filename, form='FORMATTED', status='OLD', action='READ')

        read(unit=14, fmt=*)
        read(unit=14, fmt=*) the_data%NumEl, the_data%NumNd
        allocate(the_data%NdIDs(the_data%NumNd))
        allocate(local_node_numbers(the_data%NumNd))
        allocate(the_data%ElIDs(the_data%NumEl))
        allocate(local_elem_numbers(the_data%NumEl))
        allocate(the_data%NdCoords(dim1*the_data%NumNd))
        allocate(the_data%bathymetry(the_data%NumNd))
        allocate(the_data%ElConnect(NumND_per_El*the_data%NumEl))
        allocate(the_data%NdOwners(the_data%NumNd))
        allocate(the_data%ElTypes(the_data%NumEl))

        read(unit=18, fmt=*)
        read(unit=18, fmt=*)
        read(unit=18, fmt=*) local_elem_numbers
        the_data%ElIDs = abs(local_elem_numbers)
        read(unit=18, fmt=*) garbage1, num_global_nodes, garbage2, garbage3
        read(unit=18, fmt=*) local_node_numbers
        the_data%NumOwnedND = 0
        do i1 = 1, the_data%NumNd, 1
            if (local_node_numbers(i1) > 0) then
                the_data%NumOwnedND = the_data%NumOwnedND + 1
            end if
        end do
        the_data%NdIDs = abs(local_node_numbers)
        allocate(node_owner(num_global_nodes))
        allocate(the_data%owned_to_present_nodes(the_data%NumOwnedND))
        read(unit=100, fmt=*) node_owner

        do i1 = 1, the_data%NumNd, 1
            read(unit=14, fmt=*) local_node_numbers(i1), &
                the_data%NdCoords((i1-1)*dim1 + 1), &
                the_data%NdCoords((i1-1)*dim1 + 2), &
                the_data%bathymetry(i1)
        end do
        do i1 = 1, the_data%NumEl, 1
            read(unit=14, fmt=*) local_elem_numbers(i1), i_num, &
                the_data%ElConnect((i1-1)*NumND_per_El+1), &
                the_data%ElConnect((i1-1)*NumND_per_El+2), &
                the_data%ElConnect((i1-1)*NumND_per_El+3)
        end do

        do i1= 1, the_data%NumNd, 1
            the_data%NdOwners(i1) = node_owner(the_data%NdIDs(i1)) - 1
        end do

        j1 = 0
        do i1 = 1, the_data%NumNd, 1
            if (the_data%NdOwners(i1) == localPet) then
                j1 = j1 + 1
                the_data%owned_to_present_nodes(j1) = i1
            end if
        end do
        the_data%ElTypes = ESMF_MESHELEMTYPE_TRI

        close(14)
        close(18)
        close(100)
    end subroutine extract_parallel_data_from_mesh

    !> \details This function writes the input meshdata object to a \c vtu file.
    !! The \c vtu file is in \c XML format. This function can be used for both parallel
    !! and serial mesh writing. If one uses this function for parallel write, the
    !! processing element with \c localPE=0 should also enter this function, otherwise
    !! the \c pvtu file will not be written. This function assumes that the \c vtu file
    !! which we want to write does not exist. If we want to add fields to the files which
    !! are created before, we have to call write_node_field_to_vtu() function. If the user
    !! wants to add more data fields to the created \c vtu file, the \c last_write parameter
    !! should be passed <tt>.false.</tt> so that the program do not close the file.
    !! By closing we mean writing the last three closing lines in the XML \c vtu files.
    !! However, if this is the last time we want to write on the same \c vtu file, we
    !! have to pass \c last_write equal to <tt>.true.</tt>
    !! \param the_data This is the input data for which we create the vtu file
    !! \param vtu_filename This is the name of the vtu file
    !! \param last_write This parameter indicates if this is the last time we want to
    !! write something to this \c vtu file.
    subroutine write_meshdata_to_vtu(the_data, vtu_filename, last_write)
        implicit none
        type(meshdata), intent(in)     :: the_data
        character(len=*), intent(in)   :: vtu_filename
        integer                        :: localPet, petCount
        logical, intent(in)            :: last_write
        integer                        :: i1, indent, offset_counter, rc
        integer, parameter             :: dim1=2, spacedim=2, NumND_per_El=3, vtk_triangle=5
        indent = 0

        call ESMF_VMGet(vm=the_data%vm, localPet=localPet, petCount=petCount, rc=rc)
        if (rc .NE. ESMF_Success) then
            localPet = 0
            petCount = 1
        end if

        open(unit=1014, file=vtu_filename, form='FORMATTED', &
            status='UNKNOWN', action='WRITE')
        write(unit=1014, fmt="(A,A)") '<VTKFile type="UnstructuredGrid"', &
            ' version="0.1" byte_order="BigEndian">'
        indent = indent + 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            "<UnstructuredGrid>"
        indent = indent + 2
        write(unit=1014, fmt="(A,A,I0,A,I0,A)") repeat(" ",indent), &
            '<Piece NumberOfPoints="', the_data%NumNd, &
            '" NumberOfCells="', the_data%NumEl, '">'
        indent = indent + 2

        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<Points>'
        indent = indent + 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<DataArray type="Float32" NumberOfComponents="3" Format="ascii">'
        indent = indent + 2
        do i1 = 1, the_data%NumNd, 1
            write(unit=1014, fmt="(A,F0.4,' ',F0.4,' ',F0.4,' ')") repeat(" ",indent), &
                the_data%NdCoords((i1-1)*dim1 + 1), &
                the_data%NdCoords((i1-1)*dim1 + 2), 0.0
        end do
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</DataArray>'
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</Points>'

        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<Cells>'
        indent = indent + 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<DataArray type="Int32" Name="connectivity" Format="ascii">'
        indent = indent + 2
        do i1 = 1, the_data%NumEl, 1
            write(unit=1014, fmt="(A,I0,' ',I0,' ',I0,' ')") repeat(" ",indent),&
                the_data%ElConnect((i1-1)*NumND_per_El+1)-1, &
                the_data%ElConnect((i1-1)*NumND_per_El+2)-1, &
                the_data%ElConnect((i1-1)*NumND_per_El+3)-1
        end do
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</DataArray>'
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<DataArray type="Int32" Name="offsets" Format="ascii">'
        indent = indent + 2
        offset_counter = 0
        do i1 = 1, the_data%NumEl, 1
            offset_counter = offset_counter + 3
            write(unit=1014, fmt="(A,I0)") repeat(" ",indent), &
                offset_counter
        end do
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</DataArray>'
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<DataArray type="Int32" Name="types" Format="ascii">'
        indent = indent + 2
        do i1=1, the_data%NumEl, 1
            write(unit=1014, fmt="(A,I2)") repeat(" ",indent), &
                vtk_triangle
        end do
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</DataArray>'
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</Cells>'

        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<CellData Scalars="scalars">'
        indent = indent + 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<DataArray type="Int32" Name="subdomain_id" NumberOfComponents="1" Format="ascii">'
        indent = indent + 2
        do i1 = 1, the_data%NumEl, 1
            write(unit=1014, fmt="(A,I0)") repeat(" ",indent), localPet
        end do
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</DataArray>'
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</CellData>'

        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<PointData Scalars="scalars">'
        indent = indent + 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<DataArray type="Float32" Name="bathymetry" NumberOfComponents="1" Format="ascii">'
        indent = indent + 2
        do i1 = 1, the_data%NumNd, 1
            write(unit=1014, fmt="(A,F0.4)") repeat(" ",indent), &
                the_data%bathymetry(i1)
        end do
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</DataArray>'

        if (last_write) then
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</PointData>'
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</Piece>'
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</UnstructuredGrid>'
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</VTKFile>'
        end if
        close(1014)
    end subroutine

    !> \details This function writes the input array (\c field_array) and its name (\c field_name)
    !! to the vtu file (which should already exist and not closed). Refer to write_meshdata_to_vtu()
    !! to know more about opening vtu file and closing them. If the parameter \c last_write is true
    !! then we close this file and as such we should not write anything else on this file.
    subroutine write_node_field_to_vtu(field_array, field_name, vtu_filename, last_write)
        implicit none
        character(len=*), intent(in)   :: vtu_filename, field_name
        logical, intent(in)            :: last_write
        real(ESMF_KIND_R8), intent(in) :: field_array(:)
        integer                        :: i1, indent, num_recs
        open(unit=1014, file=vtu_filename, form='FORMATTED', &
            position='APPEND', status='OLD', action='WRITE')

        indent = 8
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '<DataArray type="Float32" Name="'//field_name//'" NumberOfComponents="1" Format="ascii">'
        indent = indent + 2
        num_recs = size(field_array)
        do i1 = 1, num_recs, 1
            write(unit=1014, fmt="(A,F0.4)") repeat(" ",indent), field_array(i1)
        end do
        indent = indent - 2
        write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
            '</DataArray>'

        if (last_write) then
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</PointData>'
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</Piece>'
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</UnstructuredGrid>'
            indent = indent - 2
            write(unit=1014, fmt="(A,A)") repeat(" ",indent), &
                '</VTKFile>'
        end if
        close(1014)
    end subroutine

    !> \details This function creates an object of type meshdata from the fort14 file given by
    !!fort14_filename. Unlike extract_parallel_data_from_mesh(), this function does not
    !! create a parallel meshdata, so it can be called by only one PE and the created meshdata
    !! object can later be used to create an ESMF_Mesh object.
    subroutine extract_global_data_from_fort14(fort14_filename, the_data)
        implicit none
        type(meshdata), intent(inout)         :: the_data
        character(len=*), intent(in)          :: fort14_filename
        integer                               :: i1, i_num
        integer, parameter                    :: dim1=2, spacedim=2, NumND_per_El=3

        open(unit=14, file=fort14_filename, form='FORMATTED', status='OLD', action='READ')
        read(unit=14, fmt=*)
        read(unit=14, fmt=*) the_data%NumEl, the_data%NumNd
        allocate(the_data%NdIDs(the_data%NumNd))
        allocate(the_data%ElIDs(the_data%NumEl))
        allocate(the_data%NdCoords(dim1*the_data%NumNd))
        allocate(the_data%bathymetry(the_data%NumNd))
        allocate(the_data%ElConnect(NumND_per_El*the_data%NumEl))
        allocate(the_data%NdOwners(the_data%NumNd))
        allocate(the_data%ElTypes(the_data%NumEl))
        do i1 = 1, the_data%NumNd, 1
            read(unit=14, fmt=*) the_data%NdIDs(i1), &
                the_data%NdCoords((i1-1)*dim1 + 1), &
                the_data%NdCoords((i1-1)*dim1 + 2), &
                the_data%bathymetry(i1)
        end do
        do i1 = 1, the_data%NumEl, 1
            read(unit=14, fmt=*) the_data%ElIDs(i1), i_num, &
                the_data%ElConnect((i1-1)*NumND_per_El+1), &
                the_data%ElConnect((i1-1)*NumND_per_El+2), &
                the_data%ElConnect((i1-1)*NumND_per_El+3)
        end do
        the_data%NdOwners = 0
        the_data%ElTypes = ESMF_MESHELEMTYPE_TRI
        close(14)
    end subroutine

    !> \details Given a local array in each PE i.e. \c fieldarray, we use MPI_Gather method to
    !! gather their elements into an array (\c out_fieldarray) in \c PE=root. For this
    !! process we use an ESMF_VM which is given to this function as an input. Since, MPI_Gather
    !! is collective this function should also be called collectively.
    subroutine gather_datafield_on_root(vm1, fieldarray, root, num_total_nodes, out_fieldarray)
        implicit none

        type(ESMF_VM), intent(in)                       :: vm1
        real(ESMF_KIND_R8), pointer, intent(in)         :: fieldarray(:)
        real(ESMF_KIND_R8), pointer, intent(out)        :: out_fieldarray(:)
        integer, intent(in)                             :: root, num_total_nodes
        integer                                         :: send_count, localPet, petCount, &
                                                           i1, j1, k1, i_num, j_num1, rc, trash2, trash3
        integer, allocatable                            :: recv_counts(:), gather_displs(:)
        real(ESMF_KIND_R8), allocatable                 :: temp_fieldarray(:)
        character(len=6)                                :: PE_ID
        character(len=4)                                :: trash1

        call ESMF_VMGet(vm=vm1, localPet=localPet, petCount=petCount, rc=rc)
        send_count = size(fieldarray)
        if (localPet == root) then
            allocate(recv_counts(petCount))
            allocate(gather_displs(petCount))
            gather_displs(1) = 0
            recv_counts = 0
            open(unit=100, file="fine/partmesh.txt", form='FORMATTED', &
                status='OLD', action='READ')
            do i1 = 1, num_total_nodes, 1
                read(100,*) i_num
                recv_counts(i_num) = recv_counts(i_num) + 1
            end do
            do i1 = 2, petCount, 1
                gather_displs(i1) = gather_displs(i1-1) + recv_counts(i1-1)
            end do
            allocate(temp_fieldarray(num_total_nodes))
            allocate(out_fieldarray(num_total_nodes))
            close(100)
        end if

        call MPI_Gatherv(fieldarray, send_count, MPI_DOUBLE_PRECISION, &
            temp_fieldarray, recv_counts, gather_displs, MPI_DOUBLE_PRECISION, &
            0, MPI_COMM_WORLD, rc)
        if (localPet == 0) print *, "gathered on root: ", rc

        if (localPet == 0) then
            do i1 = 1, petCount, 1
                write(PE_ID, "(A,I4.4)") 'PE', i1-1
                open(unit=18, file="fine/"//PE_ID//"/fort.18", form='FORMATTED', &
                    status='OLD', action='READ')
                read(unit=18, fmt=*)
                read(unit=18, fmt=*) trash1, trash2, trash3, i_num
                do j1 = 1, i_num, 1
                    read(unit=18, fmt=*)
                end do
                k1 = 0
                read(unit=18, fmt=*) trash1, trash2, trash3, i_num
                do j1 = 1, i_num, 1
                    read(unit=18, fmt=*) j_num1
                    if (j_num1 > 0) then
                        k1 = k1 + 1
                        out_fieldarray(j_num1) = temp_fieldarray(gather_displs(i1)+k1)
                    end if
                end do
            end do
        end if
    end subroutine

    !>
    !!
    !!
    subroutine gather_nodal_hotdata_on_root(localized_hotdata, global_hotdata, &
            localized_meshdata, global_meshdata, root)
        implicit none
        real(ESMF_KIND_R8), pointer       :: localfieldarray_ptr(:), globalfieldarray_ptr(:)
        type(hotdata), intent(in)         :: localized_hotdata
        type(hotdata), intent(inout)      :: global_hotdata
        type(meshdata), intent(in)        :: localized_meshdata
        type(meshdata), intent(in)        :: global_meshdata
        integer                           :: root, localPet, petCount, rc

        call ESMF_VMGet(vm=localized_meshdata%vm, localPet=localPet, petCount=petCount, rc=rc)
        allocate(localfieldarray_ptr(localized_meshdata%NumOwnedNd))

        localfieldarray_ptr = localized_hotdata%ETA1
        call gather_datafield_on_root(localized_meshdata%vm, localfieldarray_ptr, &
            root, global_meshdata%NumNd, globalfieldarray_ptr)
        if (localPet == root) global_hotdata%ETA1 = globalfieldarray_ptr
        !
        localfieldarray_ptr = localized_hotdata%ETA2
        call gather_datafield_on_root(localized_meshdata%vm, localfieldarray_ptr, &
            root, global_meshdata%NumNd, globalfieldarray_ptr)
        if (localPet == root) global_hotdata%ETA2 = globalfieldarray_ptr
        !
        localfieldarray_ptr = localized_hotdata%ETADisc
        call gather_datafield_on_root(localized_meshdata%vm, localfieldarray_ptr, &
            root, global_meshdata%NumNd, globalfieldarray_ptr)
        if (localPet == root) global_hotdata%ETADisc = globalfieldarray_ptr
        !
        localfieldarray_ptr = localized_hotdata%UU2
        call gather_datafield_on_root(localized_meshdata%vm, localfieldarray_ptr, &
            root, global_meshdata%NumNd, globalfieldarray_ptr)
        if (localPet == root) global_hotdata%UU2 = globalfieldarray_ptr
        !
        localfieldarray_ptr = localized_hotdata%VV2
        call gather_datafield_on_root(localized_meshdata%vm, localfieldarray_ptr, &
            root, global_meshdata%NumNd, globalfieldarray_ptr)
        if (localPet == root) global_hotdata%VV2 = globalfieldarray_ptr
        !
        localfieldarray_ptr = localized_hotdata%CH1
        call gather_datafield_on_root(localized_meshdata%vm, localfieldarray_ptr, &
            root, global_meshdata%NumNd, globalfieldarray_ptr)
        if (localPet == root) global_hotdata%CH1 = globalfieldarray_ptr
    end subroutine

    !>
    !!
    !!
    subroutine extract_hotdata_from_parallel_binary_fort_67(the_meshdata, the_hotdata, global_fort14_dir, write_ascii)
        implicit none
        type(meshdata), intent(in)   :: the_meshdata
        type(hotdata), intent(out)   :: the_hotdata
        character(len=*), intent(in) :: global_fort14_dir
        logical, intent(in)          :: write_ascii
        integer                      :: i1, localPet, petCount, rc, ihotstp
        character(len=6)             :: PE_ID
        character(len=200)           :: fort67_filename, fort67_ascii_filename

        call ESMF_VMGet(vm=the_meshdata%vm, localPet=localPet, petCount=petCount, rc=rc)
        call allocate_hotdata(the_hotdata, the_meshdata)

        write(PE_ID, "(A,I4.4)") "PE", localPet
        fort67_filename = trim(global_fort14_dir//PE_ID//"/fort.67")
        open(unit=67, file=fort67_filename, action='READ', &
            access='DIRECT', recl=8, iostat=rc, status='OLD')
        ihotstp=1
        read(unit=67, REC=ihotstp) the_hotdata%InputFileFmtVn;
        ihotstp=ihotstp+1
        read(unit=67, REC=ihotstp) the_hotdata%IMHS;
        ihotstp=ihotstp+1
        read(unit=67, REC=ihotstp) the_hotdata%TimeLoc;
        ihotstp=ihotstp+1
        read(unit=67, REC=ihotstp) the_hotdata%ITHS;
        ihotstp=ihotstp+1
        read(unit=67, REC=ihotstp) the_hotdata%NP_G_IN;
        ihotstp=ihotstp+1
        read(unit=67, REC=ihotstp) the_hotdata%NE_G_IN;
        ihotstp=ihotstp+1
        read(unit=67, REC=ihotstp) the_hotdata%NP_A_IN;
        ihotstp=ihotstp+1
        read(unit=67, REC=ihotstp) the_hotdata%NE_A_IN;
        ihotstp=ihotstp+1

        do i1 = 1, the_meshdata%NumNd, 1
            read(unit=67, REC=ihotstp) the_hotdata%ETA1(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            read(unit=67, REC=ihotstp) the_hotdata%ETA2(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            read(unit=67, REC=ihotstp) the_hotdata%ETADisc(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            read(unit=67, REC=ihotstp) the_hotdata%UU2(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            read(unit=67, REC=ihotstp) the_hotdata%VV2(i1)
            ihotstp=ihotstp+1
        end do
        if (the_hotdata%IMHS.EQ.10) then
            do i1 = 1, the_meshdata%NumNd, 1
                read(unit=67, REC=ihotstp) the_hotdata%CH1(i1)
                ihotstp=ihotstp+1
            end do
        end if
        do i1 = 1, the_meshdata%NumNd, 1
            read(unit=67, REC=ihotstp) the_hotdata%NNODECODE(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumEl, 1
            read(unit=67, REC=ihotstp) the_hotdata%NOFF(i1)
            ihotstp=ihotstp+1
        end do

        read(unit=67,REC=ihotstp) the_hotdata%IESTP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUE
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IVSTP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUV
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%ICSTP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUC
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IPSTP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IWSTP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUM
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IGEP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUGE
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IGVP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUGV
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IGCP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUGC
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IGPP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%IGWP
        ihotstp=ihotstp+1
        read(unit=67,REC=ihotstp) the_hotdata%NSCOUGW
        ihotstp=ihotstp+1
        close(67)

        if (write_ascii) then
            fort67_ascii_filename = trim(global_fort14_dir//PE_ID//"/fort.67")//".txt"
            open(unit=670, file=fort67_ascii_filename, form='FORMATTED', &
                action='WRITE', iostat=rc)
            write(unit=670, fmt=*) the_hotdata%InputFileFmtVn
            write(unit=670, fmt=*) the_hotdata%IMHS
            write(unit=670, fmt=*) the_hotdata%TimeLoc
            write(unit=670, fmt=*) the_hotdata%ITHS
            write(unit=670, fmt=*) the_hotdata%NP_G_IN
            write(unit=670, fmt=*) the_hotdata%NE_G_IN
            write(unit=670, fmt=*) the_hotdata%NP_A_IN
            write(unit=670, fmt=*) the_hotdata%NE_A_IN
            write(unit=670, fmt=*) the_hotdata%ETA1
            write(unit=670, fmt=*) the_hotdata%ETA2
            write(unit=670, fmt=*) the_hotdata%ETADisc
            write(unit=670, fmt=*) the_hotdata%UU2
            write(unit=670, fmt=*) the_hotdata%VV2
            write(unit=670, fmt=*) the_hotdata%CH1
            write(unit=670, fmt=*) the_hotdata%NNODECODE
            write(unit=670, fmt=*) the_hotdata%NOFF
            write(unit=670, fmt=*) the_hotdata%IESTP, the_hotdata%NSCOUE, the_hotdata%IVSTP, &
                the_hotdata%NSCOUV, the_hotdata%ICSTP, the_hotdata%NSCOUC, the_hotdata%IPSTP, &
                the_hotdata%IWSTP, the_hotdata%NSCOUM, the_hotdata%IGEP, the_hotdata%NSCOUGE, &
                the_hotdata%IGVP, the_hotdata%NSCOUGV, the_hotdata%IGCP, the_hotdata%NSCOUGC, &
                the_hotdata%IGPP, the_hotdata%IGWP, the_hotdata%NSCOUGW
            close(670)
        end if
    end subroutine

    !>
    !!
    !!
    subroutine write_serial_hotfile_to_fort_67(the_meshdata, the_hotdata, global_fort14_dir, write_ascii)
        implicit none
        type(meshdata), intent(in)   :: the_meshdata
        type(hotdata), intent(in)    :: the_hotdata
        character(len=*), intent(in) :: global_fort14_dir
        logical, intent(in)          :: write_ascii
        integer                      :: i1, rc, ihotstp
        character(len=200)           :: fort67_filename, fort67_ascii_filename

        fort67_filename = trim(global_fort14_dir//"/fort.67")
        open(unit=67, file=fort67_filename, action='WRITE', &
            access='DIRECT', recl=8, iostat=rc, status='UNKNOWN')

        ihotstp=1
        write(unit=67, REC=ihotstp) the_hotdata%InputFileFmtVn;
        ihotstp=ihotstp+1
        write(unit=67, REC=ihotstp) the_hotdata%IMHS;
        ihotstp=ihotstp+1
        write(unit=67, REC=ihotstp) the_hotdata%TimeLoc;
        ihotstp=ihotstp+1
        write(unit=67, REC=ihotstp) the_hotdata%ITHS;
        ihotstp=ihotstp+1
        write(unit=67, REC=ihotstp) the_hotdata%NP_G_IN;
        ihotstp=ihotstp+1
        write(unit=67, REC=ihotstp) the_hotdata%NE_G_IN;
        ihotstp=ihotstp+1
        write(unit=67, REC=ihotstp) the_hotdata%NP_A_IN;
        ihotstp=ihotstp+1
        write(unit=67, REC=ihotstp) the_hotdata%NE_A_IN;
        ihotstp=ihotstp+1

        do i1 = 1, the_meshdata%NumNd, 1
            write(unit=67, REC=ihotstp) the_hotdata%ETA1(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            write(unit=67, REC=ihotstp) the_hotdata%ETA2(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            write(unit=67, REC=ihotstp) the_hotdata%ETADisc(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            write(unit=67, REC=ihotstp) the_hotdata%UU2(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumNd, 1
            write(unit=67, REC=ihotstp) the_hotdata%VV2(i1)
            ihotstp=ihotstp+1
        end do
        if (the_hotdata%IMHS.EQ.10) then
            do i1 = 1, the_meshdata%NumNd, 1
                write(unit=67, REC=ihotstp) the_hotdata%CH1(i1)
                ihotstp=ihotstp+1
            end do
        end if
        do i1 = 1, the_meshdata%NumNd, 1
            write(unit=67, REC=ihotstp) the_hotdata%NNODECODE(i1)
            ihotstp=ihotstp+1
        end do
        do i1 = 1, the_meshdata%NumEl, 1
            write(unit=67, REC=ihotstp) the_hotdata%NOFF(i1)
            ihotstp=ihotstp+1
        end do

        write(unit=67,REC=ihotstp) the_hotdata%IESTP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUE
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IVSTP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUV
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%ICSTP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUC
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IPSTP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IWSTP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUM
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IGEP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUGE
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IGVP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUGV
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IGCP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUGC
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IGPP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%IGWP
        ihotstp=ihotstp+1
        write(unit=67,REC=ihotstp) the_hotdata%NSCOUGW
        ihotstp=ihotstp+1
        close(67)

        if (write_ascii) then
            fort67_ascii_filename = trim(global_fort14_dir//"/fort.67")//".txt"
            open(unit=670, file=fort67_ascii_filename, form='FORMATTED', &
                action='WRITE', iostat=rc)
            write(unit=670, fmt=*) the_hotdata%InputFileFmtVn
            write(unit=670, fmt=*) the_hotdata%IMHS
            write(unit=670, fmt=*) the_hotdata%TimeLoc
            write(unit=670, fmt=*) the_hotdata%ITHS
            write(unit=670, fmt=*) the_hotdata%NP_G_IN
            write(unit=670, fmt=*) the_hotdata%NE_G_IN
            write(unit=670, fmt=*) the_hotdata%NP_A_IN
            write(unit=670, fmt=*) the_hotdata%NE_A_IN
            write(unit=670, fmt=*) the_hotdata%ETA1
            write(unit=670, fmt=*) the_hotdata%ETA2
            write(unit=670, fmt=*) the_hotdata%ETADisc
            write(unit=670, fmt=*) the_hotdata%UU2
            write(unit=670, fmt=*) the_hotdata%VV2
            write(unit=670, fmt=*) the_hotdata%CH1
            write(unit=670, fmt=*) the_hotdata%NNODECODE
            write(unit=670, fmt=*) the_hotdata%NOFF
            write(unit=670, fmt=*) the_hotdata%IESTP, the_hotdata%NSCOUE, the_hotdata%IVSTP, &
                the_hotdata%NSCOUV, the_hotdata%ICSTP, the_hotdata%NSCOUC, the_hotdata%IPSTP, &
                the_hotdata%IWSTP, the_hotdata%NSCOUM, the_hotdata%IGEP, the_hotdata%NSCOUGE, &
                the_hotdata%IGVP, the_hotdata%NSCOUGV, the_hotdata%IGCP, the_hotdata%NSCOUGC, &
                the_hotdata%IGPP, the_hotdata%IGWP, the_hotdata%NSCOUGW
            close(670)
        end if
    end subroutine

    subroutine allocate_hotdata(the_hotdata, the_meshdata)
        implicit none
        type(hotdata), intent(inout)    :: the_hotdata
        type(meshdata), intent(in)      :: the_meshdata
        allocate(the_hotdata%ETA1(the_meshdata%NumNd))
        allocate(the_hotdata%ETA2(the_meshdata%NumNd))
        allocate(the_hotdata%ETADisc(the_meshdata%NumNd))
        allocate(the_hotdata%UU2(the_meshdata%NumNd))
        allocate(the_hotdata%VV2(the_meshdata%NumNd))
        allocate(the_hotdata%CH1(the_meshdata%NumNd))
        allocate(the_hotdata%NNODECODE(the_meshdata%NumNd))
        allocate(the_hotdata%NOFF(the_meshdata%NumEl))
    end subroutine

    subroutine regrid_datafield_of_present_nodes(the_regrid_data, src_data, dst_data, src_array_of_present_nodes)
        implicit none
        type(regrid_data), intent(inout)    :: the_regrid_data
        type(meshdata)                      :: src_data, dst_data
        real(ESMF_KIND_R8), intent(in)      :: src_array_of_present_nodes(:)
        integer                             :: i1, localPet, petCount, rc
        call ESMF_VMGet(vm=src_data%vm, localPet=localPet, petCount=petCount, rc=rc)
        do i1 = 1, src_data%NumOwnedNd, 1
            the_regrid_data%src_fieldptr(i1) = src_array_of_present_nodes(src_data%owned_to_present_nodes(i1))
        end do
        call ESMF_FieldRegrid(srcField=the_regrid_data%src_datafield, &
            dstField=the_regrid_data%dst_mapped_field, &
            routeHandle=the_regrid_data%mapped_route_handle, rc=rc)
        if (localPet == 0) print *, "mapped regriding: ", rc
        call ESMF_FieldRegrid(srcField=the_regrid_data%src_datafield, &
            dstField=the_regrid_data%dst_unmapped_field, &
            routeHandle=the_regrid_data%unmapped_route_handle, rc=rc)
        if (localPet == 0) print *, "unmapped regriding: ", rc
        do i1 = 1, dst_data%NumOwnedND, 1
            if (abs(the_regrid_data%dst_maskptr(i1)) < 1.d-8) then
                the_regrid_data%mapped_fieldptr(i1) = the_regrid_data%unmapped_fieldptr(i1)
            end if
        end do
    end subroutine

    !> \details This function simply deallocates the arrays created in the \c meshdata object
    !! creation steps.
    subroutine destroy_meshdata(the_data)
        implicit none
        type(meshdata), intent(inout) :: the_data
        deallocate(the_data%NdIDs)
        deallocate(the_data%ElIDs)
        deallocate(the_data%NdCoords)
        deallocate(the_data%bathymetry)
        deallocate(the_data%ElConnect)
        deallocate(the_data%NdOwners)
        deallocate(the_data%ElTypes)
    end subroutine

    subroutine destroy_hotdata(the_data)
        implicit none
        type(hotdata), intent(inout)    :: the_data
    end subroutine

    subroutine destroy_regrid_data(the_regrid_data)
        implicit none
        type(regrid_data), intent(inout)    :: the_regrid_data
        call ESMF_FieldRegridRelease(the_regrid_data%mapped_route_handle)
        call ESMF_FieldRegridRelease(the_regrid_data%unmapped_route_handle)
        call ESMF_FieldDestroy(the_regrid_data%src_datafield)
        call ESMF_FieldDestroy(the_regrid_data%dst_mask_field)
        call ESMF_FieldDestroy(the_regrid_data%dst_mapped_field)
        call ESMF_FieldDestroy(the_regrid_data%dst_unmapped_field)
    end subroutine

end module ADCIRC_interpolation

!> \mainpage
!! ## Introduction
!! \ref adcirc_interpolation "ADCIRC interpolation module" provides required types and
!! functions to interpolate data between two ADCIRC meshes.
!! We use this module to first create an object of type \ref adcirc_interpolation::meshdata
!! "meshdata" from ADCIRC input files, and then use the created meshdata object to construct an
!! ESMF_Mesh object. When we have two ESMF_Mesh objects, we can use them to interpolate
!! data between them. All of this process can either be done
!! sequentially or in parallel.
!! ### Sequential interpolation
!! For sequential interpolation we use the following procedure:
!!   1. Use the subroutine \ref adcirc_interpolation::extract_global_data_from_fort14()
!!      "extract_global_data_from_fort14()" to create two objects of type
!!      \ref adcirc_interpolation::meshdata "meshdata". One of these objects is used
!!      as source mesh where we want to interpolate from, and the other is used as
!!      destination mesh where we want to interpolate to.
!!   2. Create two ESMF_Mesh objects from the above \ref adcirc_interpolation::meshdata
!!      "meshdata"'s, using \ref adcirc_interpolation::create_parallel_esmf_mesh_from_meshdata
!!      "create_parallel_esmf_mesh_from_meshdata" subroutine.
!!   3. Create two \c ESMF_Field 's on the above \c ESMF_Mesh 's.
!!   4. Use ESMF library to interpolate data from the source mesh to destination mesh for
!!      those nodes that we have enough data, and extrapolate for those nodes that we do
!!      not have enough data.
!!
!! ### Parallel interpolation
!! The process is very much similar to the sequential case except in the first step we
!! use the function \ref adcirc_interpolation::extract_parallel_data_from_mesh
!! "extract_parallel_data_from_mesh" to extract mesh data from the files <tt> fort.14, fort.18,
!! partmesh.txt</tt>.
!! ## Basic Usage
!! Here, we present an example of how the module adcirc_interpolation should be used.
!! Consider the following two meshes of east coast. We have decomposed each of these meshes
!! into 4 subdomain, which are shown with different colors here. The subdomain decomposition
!! is done by adcprep. The coarse mesh is used as the source mesh and the fine mesh is our
!! destination mesh. We want to interpolate the bathymetry from the source mesh to the
!! destination mesh.
!! <img src="Images/coarse_mesh_subdomains.png" width=600em />
!! <div style="text-align:center; font-size:150%;">The decomposed coarse mesh, which is used as the source mesh.</div>
!! <img src="Images/fine_mesh_subdomains.png" width=600em />
!! <div style="text-align:center; font-size:150%;">The decomposed fine mesh, which is used as the destination mesh.</div>
!! We use the following code for this purpose. The comments in the code make the overall
!! procedure of our technique more clear.
!!
!! \code{.f90}
!!    program main
!!
!!        use ESMF
!!        use MPI
!!        use ADCIRC_interpolation
!!
!!        implicit none
!!        real(ESMF_KIND_R8), pointer                      :: src_fieldptr(:), mapped_fieldptr(:), unmapped_fieldptr(:), &
!!            dst_maskptr(:), global_fieldptr(:)
!!        type(ESMF_VM)                                    :: vm1
!!        type(meshdata)                                   :: src_data, dst_data, global_src_data, global_dst_data
!!        type(ESMF_Mesh)                                  :: src_mesh, dst_mesh
!!        type(ESMF_Field)                                 :: src_datafield, dst_unmapped_field, dst_mapped_field, dst_mask_field
!!        type(ESMF_RouteHandle)                           :: mapped_route_handle, unmapped_route_handle
!!        integer                                          :: i1, rc, localPet, petCount
!!        character(len=6)                                 :: PE_ID
!!        character(len=:), parameter                      :: src_fort14_dir = "coarse/", dst_fort14_dir = "fine/"
!!
!!        !
!!        ! Any program using ESMF library should start with ESMF_Initialize(...).
!!        ! Next we get the ESMF_VM (virtual machine) and using this VM, we obtain
!!        ! the ID of our local PE and total number of PE's in the communicator.
!!        !
!!        call ESMF_Initialize(vm=vm1, defaultLogFilename="test.log", &
!!            logKindFlag=ESMF_LOGKIND_MULTI, rc=rc)
!!        call ESMF_VMGet(vm=vm1, localPet=localPet, petCount=petCount, rc=rc)
!!        write(PE_ID, "(A,I4.4)") "PE", localPet
!!
!!        !
!!        ! Next, we create our meshdata objects for source and destination meshes,
!!        ! and using those meshdata objects, we create the ESMF_Mesh objects, and
!!        ! we write the mesh into parallel vtu outputs.
!!        !
!!        call extract_parallel_data_from_mesh(vm1, src_fort14_dir, src_data)
!!        call create_parallel_esmf_mesh_from_meshdata(src_data, src_mesh)
!!        call extract_parallel_data_from_mesh(vm1, dst_fort14_dir, dst_data)
!!        call create_parallel_esmf_mesh_from_meshdata(dst_data, dst_mesh)
!!        call write_meshdata_to_vtu(src_data, PE_ID//"_src_mesh.vtu", .true.)
!!        call write_meshdata_to_vtu(dst_data, PE_ID//"_dst_mesh.vtu", .true.)
!!
!!        !
!!        ! After this point, we plan to overcome an important issue. The issue is
!!        ! if a point in the destination mesh is outside of the source mesh, we cannot
!!        ! use ESMF bilinear interpolation to transform our datafields. Hence, we first
!!        ! create a mask in the destination mesh, with its values equal to zero on the
!!        ! nodes outside of the source mesh domain, and one on the nodes which are inside
!!        ! the source mesh. Afterwards, we use bilinear interpolation for mask=1, and
!!        ! nearest node interpolation for mask=0. Thus, we need four ESMF_Fields:
!!        !   1- An ESMF_Field on the source mesh, which is used for the mask creation
!!        !      and also datafield interpolation.
!!        !   2- An ESMF_Field on the destination mesh, which will be only used for mask
!!        !      creation.
!!        !   3- An ESMF_Field on the destination mesh, which will be used for interpolating
!!        !      data on the destination points with mask=1.
!!        !   4- An ESMF_Field on the destination mesh, which will be used for interpolating
!!        !      data on the destination points with mask=0.
!!        !
!!        src_datafield = ESMF_FieldCreate(mesh=src_mesh, typekind=ESMF_TYPEKIND_R8, rc=rc)
!!        dst_mask_field = ESMF_FieldCreate(mesh=dst_mesh, typekind=ESMF_TYPEKIND_R8, rc=rc)
!!        dst_mapped_field = ESMF_FieldCreate(mesh=dst_mesh, typekind=ESMF_TYPEKIND_R8, rc=rc)
!!        dst_unmapped_field = ESMF_FieldCreate(mesh=dst_mesh, typekind=ESMF_TYPEKIND_R8, rc=rc)
!!
!!        !
!!        ! This is the preferred procedure in using ESMF to get a pointer to the
!!        ! ESMF_Field data array, and use that pointer for creating the mask, or
!!        ! assigning the data to field.
!!        !
!!        call ESMF_FieldGet(src_datafield, farrayPtr=src_fieldptr, rc=rc)
!!        call ESMF_FieldGet(dst_mask_field, farrayPtr=dst_maskptr, rc=rc)
!!        call ESMF_FieldGet(dst_mapped_field, farrayPtr=mapped_fieldptr, rc=rc)
!!        call ESMF_FieldGet(dst_unmapped_field, farrayPtr=unmapped_fieldptr, rc=rc)
!!
!!        !
!!        ! At this section, we construct our interpolation operator (A matrix which maps
!!        ! source values to destination values). Here, no actual interpolation will happen,
!!        ! only the interpolation matrices will be constructed. We construct one matrix for
!!        ! nodal points with mask=1, and one for those points with mask=0.
!!        !
!!        call ESMF_FieldRegridStore(srcField=src_datafield, dstField=dst_mask_field, &
!!            unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, &
!!            routeHandle=mapped_route_handle, regridmethod=ESMF_REGRIDMETHOD_BILINEAR, &
!!            rc=rc)
!!        call ESMF_FieldRegridStore(srcField=src_datafield, dstField=dst_unmapped_field, &
!!            unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, &
!!            routeHandle=unmapped_route_handle, regridmethod=ESMF_REGRIDMETHOD_NEAREST_STOD, &
!!            rc=rc)
!!
!!        !
!!        ! This is the place that we create our mask on the destination mesh. By mask,
!!        ! we mean an array with length equal to number of nodes, whose values are equal
!!        ! to 1 at mapped nodes and 0 on unmapped nodes.
!!        !
!!        src_fieldptr = 1.d0
!!        call ESMF_FieldRegrid(srcField=src_datafield, dstField=dst_mask_field, &
!!            routehandle=mapped_route_handle, rc=rc)
!!
!!        !
!!        ! As a test for our interpolation, we use the bathymetry in the source mesh as our
!!        ! field to be inerpolated and add 1.d4 to its values at different points. Next, we
!!        ! interpoalte, source field to destination field.
!!        !
!!        do i1 = 1, src_data%NumOwnedNd, 1
!!            src_fieldptr(i1) = src_data%bathymetry(src_data%owned_to_present_nodes(i1)) + 1.d4
!!        end do
!!        call ESMF_FieldRegrid(srcField=src_datafield, dstField=dst_mapped_field, &
!!            routeHandle=mapped_route_handle, rc=rc)
!!        print *, "mapped regriding: ", rc
!!        call ESMF_FieldRegrid(srcField=src_datafield, dstField=dst_unmapped_field, &
!!            routeHandle=unmapped_route_handle, rc=rc)
!!        print *, "unmapped regriding: ", rc
!!        do i1 = 1, dst_data%NumOwnedND, 1
!!            if (abs(dst_maskptr(i1)) < 1.d-8) then
!!                mapped_fieldptr(i1) = unmapped_fieldptr(i1)
!!            end if
!!        end do
!!
!!        !
!!        ! Finally, we want to visualize our results. This is not required in actual usage.
!!        ! We only do this for our presentation. So we write two meshes in the PE=0, and
!!        ! gather the interpolated field in PE=0. Then we plot these into vtu output.
!!        !
!!        if (localPet == 0) then
!!            call extract_global_data_from_fort14("coarse/fort.14", global_src_data)
!!            call write_meshdata_to_vtu(global_src_data, "coarse/global_mesh.vtu", .true.)
!!            call extract_global_data_from_fort14("fine/fort.14", global_dst_data)
!!            call write_meshdata_to_vtu(global_dst_data, "fine/global_mesh.vtu", .false.)
!!        end if
!!        call gather_datafield_on_root(vm1, mapped_fieldptr, 0, global_dst_data%NumNd, &
!!            global_fieldptr)
!!        if (localPet == 0) then
!!            call write_node_field_to_vtu(global_fieldptr, "interp_bath", "fine/global_mesh.vtu", .true.)
!!        end if
!!
!!        !
!!        ! Finally, we have to release the memory.
!!        !
!!        if (localPet == 0) then
!!            deallocate(global_fieldptr)
!!            call destroy_meshdata(global_dst_data)
!!            call destroy_meshdata(global_src_data)
!!        end if
!!        call ESMF_FieldRegridRelease(mapped_route_handle)
!!        call ESMF_FieldRegridRelease(unmapped_route_handle)
!!        call ESMF_FieldDestroy(src_datafield)
!!        call ESMF_FieldDestroy(dst_mask_field)
!!        call ESMF_FieldDestroy(dst_mapped_field)
!!        call ESMF_FieldDestroy(dst_unmapped_field)
!!        call ESMF_MeshDestroy(dst_mesh)
!!        call ESMF_MeshDestroy(src_mesh)
!!        call destroy_meshdata(src_data)
!!        call destroy_meshdata(dst_data)
!!
!!        call ESMF_Finalize()
!!
!!    end program main
!! \endcode
!!
!! Using this code, we obtain the following results:
!! <img src="Images/coarse_bath_plus_10000.png" width=750em />
!! <div style="text-align:center; font-size:150%;">Original data (bathymetry + 10000.) on the coarse mesh.</div>
!! <img src="Images/fine_bath_plus_10000.png" width=750em />
!! <div style="text-align:center; font-size:150%;">Original data (bathymetry + 10000.) on the fine mesh.</div>
!! <img src="Images/interp_bath_plus_10000.png" width=750em />
!! <div style="text-align:center; font-size:150%;">Interpolated bathymetry from coarse to fine mesh.</div>
!!
program main

    use ESMF
    use MPI
    use ADCIRC_interpolation

    implicit none
    real(ESMF_KIND_R8), pointer   :: global_fieldptr(:)
    type(ESMF_VM)                 :: vm1
    type(meshdata)                :: src_data, dst_data, global_src_data, global_dst_data
    type(hotdata)                 :: src_hotdata, dst_hotdata, global_dst_hotdata
    type(regrid_data)             :: the_regrid_data
    type(ESMF_Mesh)               :: src_mesh, dst_mesh
    integer                       :: i1, rc, localPet, petCount
    character(len=6)              :: PE_ID
    character(len=*), parameter   :: src_fort14_dir = "coarse/", dst_fort14_dir = "fine/"

    !
    ! Any program using ESMF library should start with ESMF_Initialize(...).
    ! Next we get the ESMF_VM (virtual machine) and using this VM, we obtain
    ! the ID of our local PE and total number of PE's in the communicator.
    !
    call ESMF_Initialize(vm=vm1, defaultLogFilename="test.log", &
        logKindFlag=ESMF_LOGKIND_MULTI, rc=rc)
    call ESMF_VMGet(vm=vm1, localPet=localPet, petCount=petCount, rc=rc)
    write(PE_ID, "(A,I4.4)") "PE", localPet

    !
    ! Next, we create our meshdata objects for source and destination meshes,
    ! and using those meshdata objects, we create the ESMF_Mesh objects, and
    ! we write the mesh into parallel vtu outputs.
    !
    call extract_parallel_data_from_mesh(vm1, src_fort14_dir, src_data)
    call create_parallel_esmf_mesh_from_meshdata(src_data, src_mesh)
    call extract_parallel_data_from_mesh(vm1, dst_fort14_dir, dst_data)
    call create_parallel_esmf_mesh_from_meshdata(dst_data, dst_mesh)
    call write_meshdata_to_vtu(src_data, PE_ID//"_src_mesh.vtu", .true.)
    call write_meshdata_to_vtu(dst_data, PE_ID//"_dst_mesh.vtu", .true.)

    !
    ! Now, let us read data from fort.67. We also allocate the hotdata structure for
    ! destination mesh and fields.
    !
    call extract_hotdata_from_parallel_binary_fort_67(src_data, src_hotdata, &
        src_fort14_dir, .true.)
    call allocate_hotdata(dst_hotdata, dst_data)
    if (localPet == 0) then
    end if

    !
    ! After this point, we plan to overcome an important issue. The issue is
    ! if a point in the destination mesh is outside of the source mesh, we cannot
    ! use ESMF bilinear interpolation to transform our datafields. Hence, we first
    ! create a mask in the destination mesh, with its values equal to zero on the
    ! nodes outside of the source mesh domain, and one on the nodes which are inside
    ! the source mesh. Afterwards, we use bilinear interpolation for mask=1, and
    ! nearest node interpolation for mask=0. Thus, we need four ESMF_Fields:
    !   1- An ESMF_Field on the source mesh, which is used for the mask creation
    !      and also datafield interpolation.
    !   2- An ESMF_Field on the destination mesh, which will be only used for mask
    !      creation.
    !   3- An ESMF_Field on the destination mesh, which will be used for interpolating
    !      data on the destination points with mask=1.
    !   4- An ESMF_Field on the destination mesh, which will be used for interpolating
    !      data on the destination points with mask=0.
    !
    the_regrid_data%src_datafield = ESMF_FieldCreate(mesh=src_mesh, &
        typekind=ESMF_TYPEKIND_R8, rc=rc)
    the_regrid_data%dst_mask_field = ESMF_FieldCreate(mesh=dst_mesh, &
        typekind=ESMF_TYPEKIND_R8, rc=rc)
    the_regrid_data%dst_mapped_field = ESMF_FieldCreate(mesh=dst_mesh, &
        typekind=ESMF_TYPEKIND_R8, rc=rc)
    the_regrid_data%dst_unmapped_field = ESMF_FieldCreate(mesh=dst_mesh, &
        typekind=ESMF_TYPEKIND_R8, rc=rc)

    !
    ! This is the preferred procedure in using ESMF to get a pointer to the
    ! ESMF_Field data array, and use that pointer for creating the mask, or
    ! assigning the data to field.
    !
    call ESMF_FieldGet(the_regrid_data%src_datafield, &
        farrayPtr=the_regrid_data%src_fieldptr, rc=rc)
    call ESMF_FieldGet(the_regrid_data%dst_mask_field, &
        farrayPtr=the_regrid_data%dst_maskptr, rc=rc)
    call ESMF_FieldGet(the_regrid_data%dst_mapped_field, &
        farrayPtr=the_regrid_data%mapped_fieldptr, rc=rc)
    call ESMF_FieldGet(the_regrid_data%dst_unmapped_field, &
        farrayPtr=the_regrid_data%unmapped_fieldptr, rc=rc)

    !
    ! At this section, we construct our interpolation operator (A matrix which maps
    ! source values to destination values). Here, no actual interpolation will happen,
    ! only the interpolation matrices will be constructed. We construct one matrix for
    ! nodal points with mask=1, and one for those points with mask=0.
    !
    call ESMF_FieldRegridStore(srcField=the_regrid_data%src_datafield, &
        dstField=the_regrid_data%dst_mask_field, &
        unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, &
        routeHandle=the_regrid_data%mapped_route_handle, &
        regridmethod=ESMF_REGRIDMETHOD_BILINEAR, rc=rc)
    call ESMF_FieldRegridStore(srcField=the_regrid_data%src_datafield, &
        dstField=the_regrid_data%dst_unmapped_field, &
        unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, &
        routeHandle=the_regrid_data%unmapped_route_handle, &
        regridmethod=ESMF_REGRIDMETHOD_NEAREST_STOD, rc=rc)

    !
    ! This is the place that we create our mask on the destination mesh. By mask,
    ! we mean an array with length equal to number of nodes, whose values are equal
    ! to 1 at mapped nodes and 0 on unmapped nodes.
    !
    the_regrid_data%src_fieldptr = 1.d0
    call ESMF_FieldRegrid(srcField=the_regrid_data%src_datafield, &
        dstField=the_regrid_data%dst_mask_field, &
        routehandle=the_regrid_data%mapped_route_handle, rc=rc)

    !
    ! Now we map the nodal values of ETA1, ETA2, ETADisc, UU2, VV2, CH1
    ! from the source mesh to the destination mesh.
    !
    call regrid_datafield_of_present_nodes(the_regrid_data, src_data, dst_data, src_hotdata%ETA1)
    dst_hotdata%ETA1 = the_regrid_data%mapped_fieldptr

    call regrid_datafield_of_present_nodes(the_regrid_data, src_data, dst_data, src_hotdata%ETA2)
    dst_hotdata%ETA2 = the_regrid_data%mapped_fieldptr

    call regrid_datafield_of_present_nodes(the_regrid_data, src_data, dst_data, src_hotdata%ETADisc)
    dst_hotdata%ETADisc = the_regrid_data%mapped_fieldptr

    call regrid_datafield_of_present_nodes(the_regrid_data, src_data, dst_data, src_hotdata%UU2)
    dst_hotdata%UU2 = the_regrid_data%mapped_fieldptr

    call regrid_datafield_of_present_nodes(the_regrid_data, src_data, dst_data, src_hotdata%VV2)
    dst_hotdata%VV2 = the_regrid_data%mapped_fieldptr

    call regrid_datafield_of_present_nodes(the_regrid_data, src_data, dst_data, src_hotdata%CH1)
    dst_hotdata%CH1 = the_regrid_data%mapped_fieldptr

    !
    ! Finally, we want to visualize our results. This is not required in actual usage.
    ! We only do this for our presentation. So we write two meshes in the PE=0, and
    ! gather the interpolated field in PE=0. Then we plot these into vtu output.
    !
    if (localPet == 0) then
        call extract_global_data_from_fort14("coarse/fort.14", global_src_data)
        call extract_global_data_from_fort14("fine/fort.14", global_dst_data)
        call allocate_hotdata(global_dst_hotdata, global_dst_data)

        call write_meshdata_to_vtu(global_src_data, "coarse/global_mesh.vtu", .true.)
        call write_meshdata_to_vtu(global_dst_data, "fine/global_mesh.vtu", .false.)
    end if

    call gather_nodal_hotdata_on_root(dst_hotdata, global_dst_hotdata, dst_data, global_dst_data, 0)

    call gather_datafield_on_root(vm1, the_regrid_data%mapped_fieldptr, 0, global_dst_data%NumNd, &
        global_fieldptr)
    if (localPet == 0) then
        call write_node_field_to_vtu(global_fieldptr, "interp_bath", "fine/global_mesh.vtu", .true.)
    end if

    !
    ! Now we write the hotstart mesh for the destination mesh.
    !
    if (localPet == 0) then
        global_dst_hotdata%InputFileFmtVn = src_hotdata%InputFileFmtVn
        global_dst_hotdata%IMHS = src_hotdata%IMHS
        global_dst_hotdata%TimeLoc = src_hotdata%TimeLoc
        global_dst_hotdata%ITHS = src_hotdata%ITHS
        global_dst_hotdata%NP_G_IN = global_dst_data%NumNd
        global_dst_hotdata%NE_G_IN = global_dst_data%NumEl
        global_dst_hotdata%NP_A_IN = global_dst_data%NumNd
        global_dst_hotdata%NE_A_IN = global_dst_data%NumEl
        global_dst_hotdata%NNODECODE = 1
        global_dst_hotdata%NOFF = 1
        global_dst_hotdata%IESTP = 0
        global_dst_hotdata%NSCOUE = 0
        global_dst_hotdata%IVSTP = 0
        global_dst_hotdata%NSCOUV = 0
        global_dst_hotdata%ICSTP = 0
        global_dst_hotdata%NSCOUC = 0
        global_dst_hotdata%IPSTP = 0
        global_dst_hotdata%IWSTP = 0
        global_dst_hotdata%NSCOUM = 0
        global_dst_hotdata%IGEP = 0
        global_dst_hotdata%NSCOUGE = 0
        global_dst_hotdata%IGVP = 0
        global_dst_hotdata%NSCOUGV = 0
        global_dst_hotdata%IGCP = 0
        global_dst_hotdata%NSCOUGC = 0
        global_dst_hotdata%IGPP = 0
        global_dst_hotdata%IGWP = 0
        global_dst_hotdata%NSCOUGW = 0
        call write_serial_hotfile_to_fort_67(global_dst_data, global_dst_hotdata, &
            dst_fort14_dir, .true.)
    end if

    !
    ! Finally, we have to release the memory.
    !
    if (localPet == 0) then
        deallocate(global_fieldptr)
        call destroy_meshdata(global_dst_data)
        call destroy_meshdata(global_src_data)
    end if
    call destroy_regrid_data(the_regrid_data)
    call ESMF_MeshDestroy(dst_mesh)
    call ESMF_MeshDestroy(src_mesh)
    call destroy_meshdata(src_data)
    call destroy_meshdata(dst_data)

    call ESMF_Finalize()

end program main

