module leizd_aptos_lib::math64 {

    use std::error;
    use leizd_aptos_lib::constant;

    const EOVERFLOW: u64 = 1;
    const EUNDERFLOW: u64 = 2;

    public fun to_share(amount: u64, total_amount: u64, total_shares: u64): u64 {
        if (total_shares == 0 || total_amount == 0) {
            amount
        } else {
            let result = amount * total_shares / total_amount;

            // prevent rounding error
            assert!(result != 0 || amount == 0, 0);

            result
        }
    }

    public fun to_share_roundup(amount: u64, total_amount: u64, total_shares: u64): u64 {
        if (total_amount == 0 || total_shares == 0 ) {
             amount
        } else {
            let numerator = amount * total_shares;
            let result = numerator / total_amount;

            // round up
            if (numerator % total_amount != 0) {
                result = result + 1;
            };
            result
        }   
    }

    public fun to_amount(share: u64, total_amount: u64, total_shares: u64): u64 {
        if (total_amount == 0 || total_shares == 0 ) {
            return 0
        };
        let result = share * total_amount / total_shares;

        // prevent rounding error
        assert!(result != 0 || share == 0, 0);
        result
    }

    public fun to_amount_roundup(share: u64, total_amount: u64, total_shares: u64): u64 {
        if (total_amount == 0 || total_shares == 0 ) {
            return 0
        };
        let numerator = share * total_amount;
        let result = numerator / total_shares;

        // round up
        if (numerator % total_shares != 0) {
            result = result + 1;
        };
        result
    }

    public fun utilization(total_deposits: u64, total_borrows: u64): u64 {
        if (total_deposits == 0 || total_borrows == 0) {
            0
        } else {
            (total_borrows * constant::e18_u64() / total_deposits)
        }
    }

    public fun max(a: u64, b: u64): u64 {
        if (a > b) a else b
    }

    public fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    public fun pow(n: u64, e: u64): u64 {
        if (e == 0) {
            1
        } else if (e == 1) {
            n
        } else {
            let p = pow(n, e / 2);
            p = p * p;
            if (e % 2 == 1) {
                p = p * n;
                p
            } else {
                p
            }
        }
    }

    public fun pow_10(e: u64): u64 {
        pow(10, e)
    }

    public fun is_overflow_by_add(a: u64, b: u64): bool {
        if (a == 0 || b == 0) return false;
        if (constant::u64_max() - a < b) {
            true
        } else {
            false
        }
    }
    public fun assert_overflow_by_add(a: u64, b: u64) {
        assert!(!is_overflow_by_add(a, b), error::invalid_argument(EOVERFLOW));
    }

    public fun is_underflow_by_sub(from: u64, to: u64): bool {
        if (from == 0 || to == 0) return false;
        if (from < to) {
            true
        } else {
            false
        }
    }
    public fun assert_underflow_by_sub(from: u64, to: u64) {
        assert!(!is_underflow_by_sub(from, to), error::invalid_argument(EUNDERFLOW));
    }

    #[test]
    fun test_pow() {
        let result = pow(10, 18);
        assert!(result == 1000000000000000000, 0);

        let result = pow(10, 1);
        assert!(result == 10, 0);

        let result = pow(10, 0);
        assert!(result == 1, 0);
    }
    #[test]
    fun test_is_overflow_by_add() {
        let max = constant::u64_max();
        assert!(is_overflow_by_add(max - 1, 2), 0);
        assert!(is_overflow_by_add(2, max - 1), 0);
        assert!(!is_overflow_by_add(max - 1, 1), 0);
        assert!(!is_overflow_by_add(1, max - 1), 0);
    }
    #[test]
    fun test_assert_overflow_by_add_when_not_be_overflow() {
        assert_overflow_by_add(constant::u64_max() - 1, 1);
    }
    #[test]
    #[expected_failure(abort_code = 65537)]
    fun test_assert_overflow_by_add_when_be_overflow() {
        assert_overflow_by_add(constant::u64_max() - 1, 2);
    }
    #[test]
    fun test_is_underflow_by_sub() {
        assert!(is_underflow_by_sub(2, 3), 0);
        assert!(!is_underflow_by_sub(2, 2), 0);
        assert!(!is_underflow_by_sub(2, 1), 0);
    }
    #[test]
    fun test_assert_underflow_by_sub_when_not_be_underflow() {
        assert_underflow_by_sub(1, 1);
    }
    #[test]
    #[expected_failure(abort_code = 65538)]
    fun test_assert_underflow_by_sub_when_be_underflow() {
        assert_underflow_by_sub(1, 2);
    }
}