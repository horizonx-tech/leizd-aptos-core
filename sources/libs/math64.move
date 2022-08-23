module leizd::math64 {

    use leizd::constant;

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

        // prevent rouding error
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

    public fun utilization(total_deposts: u64, total_borrows: u64): u64 {
        if (total_deposts == 0 || total_borrows == 0) {
            0
        } else {
            (total_borrows * constant::e18_u64() / total_deposts)
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

    #[test]
    public entry fun test_pow() {
        let result = pow(10, 18);
        assert!(result == 1000000000000000000, 0);

        let result = pow(10, 1);
        assert!(result == 10, 0);

        let result = pow(10, 0);
        assert!(result == 1, 0);
    }
}