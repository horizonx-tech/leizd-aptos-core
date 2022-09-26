module leizd::coin_key {

    use std::string::{String};
    use aptos_framework::type_info;

    public fun key<C>(): String {
        type_info::type_name<C>()
    }
}