/// TODO: Trying out this library to cast an integer.
module leizd::caster {

    public fun to_u64(amount: u128): u64 {
        (amount as u64)
    }

    public fun to_u128(amount: u64): u128 {
        (amount as u128)
    }
}