module leizd_aptos_common::position_type {

    use std::error;
    use aptos_std::comparator;
    use aptos_framework::type_info;

    struct AssetToShadow {}
    struct ShadowToAsset {}

    const E_NOT_POSITION_TYPE: u64 = 1;

    public fun is_asset_to_shadow<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_of<P>(),
                &type_info::type_of<AssetToShadow>(),
            )
        )
    }

    public fun is_shadow_to_asset<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_of<P>(),
                &type_info::type_of<ShadowToAsset>(),
            )
        )
    }

    public fun assert_position_type<P>() {
        assert!(is_asset_to_shadow<P>() || is_shadow_to_asset<P>(), error::invalid_argument(E_NOT_POSITION_TYPE));
    }

    #[test_only]
    struct DummyType {}
    #[test]
    fun test_is_type_xxx() {
        assert!(is_asset_to_shadow<AssetToShadow>(), 0);
        assert!(!is_asset_to_shadow<ShadowToAsset>(), 0);
        assert!(!is_asset_to_shadow<DummyType>(), 0);
        assert!(!is_shadow_to_asset<AssetToShadow>(), 0);
        assert!(is_shadow_to_asset<ShadowToAsset>(), 0);
        assert!(!is_shadow_to_asset<DummyType>(), 0);
    }
    #[test]
    fun test_assert_pool_type() {
        assert_position_type<AssetToShadow>();
        assert_position_type<ShadowToAsset>();
    }
    #[test]
    #[expected_failure(abort_code = 65537)]
    fun test_assert_pool_type_withnot_pool_type() {
        assert_position_type<DummyType>();
    }
}