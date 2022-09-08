module leizd::pool_type {

    use std::string;
    use aptos_framework::comparator;
    use aptos_framework::type_info;

    struct Asset {}
    struct Shadow {}

    public fun is_type_asset<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_name<P>(),
                &string::utf8(b"0x123456789abcdef::pool_type::Asset"),
            )
        )
    }

    public fun is_type_shadow<P>():bool {
        comparator::is_equal(
            &comparator::compare(
                &type_info::type_name<P>(),
                &string::utf8(b"0x123456789abcdef::pool_type::Shadow"),
            )
        )
    }

    public fun assert_pool_type<P>() {
        assert!(is_type_asset<P>() || is_type_shadow<P>(), 0);
    }
}