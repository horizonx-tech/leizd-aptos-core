module leizd_aptos_common::pool_type {

    use std::error;
    use aptos_framework::comparator;
    use aptos_framework::type_info;

    struct Asset {}
    struct Shadow {}

    const ENOT_POOL_TYPE: u64 = 1;

    public fun is_type_asset<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_of<P>(),
                &type_info::type_of<Asset>(),
            )
        )
    }

    public fun is_type_shadow<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_of<P>(),
                &type_info::type_of<Shadow>(),
            )
        )
    }

    public fun assert_pool_type<P>() {
        assert!(is_type_asset<P>() || is_type_shadow<P>(), error::invalid_argument(ENOT_POOL_TYPE));
    }

    #[test_only]
    struct DummyType {}
    #[test]
    fun test_is_type_xxx() {
        assert!(is_type_asset<Asset>(), 0);
        assert!(!is_type_asset<Shadow>(), 0);
        assert!(!is_type_asset<DummyType>(), 0);
        assert!(!is_type_shadow<Asset>(), 0);
        assert!(is_type_shadow<Shadow>(), 0);
        assert!(!is_type_shadow<DummyType>(), 0);
    }
    #[test]
    fun test_assert_pool_type() {
        assert_pool_type<Asset>();
        assert_pool_type<Shadow>();
    }
    #[test]
    #[expected_failure(abort_code = 65537)]
    fun test_assert_pool_type_with_not_pool_type() {
        assert_pool_type<DummyType>();
    }
}