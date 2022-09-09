module leizd::pool_type {

    use aptos_framework::comparator;
    use aptos_framework::type_info;

    struct Asset {}
    struct Shadow {}

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
        assert!(is_type_asset<P>() || is_type_shadow<P>(), 0);
    }

    #[test_only]
    struct DummyPoolType {}
    #[test]
    fun test_is_type_xxx() {
        assert!(is_type_asset<Asset>(), 0);
        assert!(!is_type_asset<Shadow>(), 0);
        assert!(!is_type_asset<DummyPoolType>(), 0);
        assert!(is_type_asset<Asset>(), 0);
        assert!(!is_type_asset<Shadow>(), 0);
        assert!(!is_type_asset<DummyPoolType>(), 0);
    }
    #[test]
    fun test_assert_pool_type() {
        assert_pool_type<Asset>();
        assert_pool_type<Shadow>();
    }
    #[test]
    #[expected_failure(abort_code = 0)]
    fun test_assert_pool_type_withnot_pool_type() {
        assert_pool_type<DummyPoolType>();
    }
}