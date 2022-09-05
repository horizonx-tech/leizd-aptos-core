module leizd::position_type {

    use std::string;
    use aptos_framework::comparator;
    use aptos_framework::type_info;

    struct AssetToShadow {}
    struct ShadowToAsset {}

    public fun is_asset_to_shadow<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_name<P>(),
                &string::utf8(b"0x123456789abcdef::position_type::AssetToShadow"),
            )
        )
    }

    public fun is_shadow_to_asset<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_name<P>(),
                &string::utf8(b"0x123456789abcdef::position_type::ShadowToAsset"),
            )
        )
    }
}