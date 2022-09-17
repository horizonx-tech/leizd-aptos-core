module leizd_aptos_lib::math128 {

    public fun to_share(amount: u128, total_amount: u128, total_shares: u128): u128 {
        if (total_shares == 0 || total_amount == 0) {
            amount
        } else {
            let result = amount * total_shares / total_amount;

            // prevent rounding error
            assert!(result != 0 || amount == 0, 0);

            result
        }
    }

    public fun to_share_roundup(amount: u128, total_amount: u128, total_shares: u128): u128 {
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

    public fun to_amount(share: u128, total_amount: u128, total_shares: u128): u128 {
        if (total_amount == 0 || total_shares == 0 ) {
            return 0
        };
        let result = share * total_amount / total_shares;

        // prevent rouding error
        assert!(result != 0 || share == 0, 0);
        result
    }

    public fun to_amount_roundup(share: u128, total_amount: u128, total_shares: u128): u128 {
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

    public fun utilization(dp: u128, total_deposts: u128, total_borrows: u128): u128 {
        if (total_deposts == 0 || total_borrows == 0) {
            0
        } else {
            (total_borrows * dp / total_deposts)
        }
    }

    public fun max(a: u128, b: u128): u128 {
        if (a > b) a else b
    }

    public fun min(a: u128, b: u128): u128 {
        if (a < b) a else b
    }

    public fun pow(n: u128, e: u128): u128 {
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

    #[test]
    public entry fun test_to_share() {
        assert!(to_share(100, 500, 100000) == 20000, 0);
    }
}