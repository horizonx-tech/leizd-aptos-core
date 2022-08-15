module leizd::interest_rate {

    use leizd::math;

    friend leizd::pool;

    const DECIMAL_PRECISION: u64 = 1000000000000000000;

    /// X_MAX = ln(RCOMP_MAX + 1)
    const X_MAX: u64 = 11090370147631773313;

    struct Config<phantom C> has key {
        uopt: u64,
        ucrit: u64,
        ulow: u64,
        ki: u64,
        kcrit: u64,
        klow: u64,
        klin: u64,
        beta: u64,
        ri: u64,
        t_crit: u64
    }

    public(friend) entry fun initialize<C>(owner: &signer) {
        move_to(owner, default_config<C>());
    }
    
    public fun default_config<C>(): Config<C> {
        Config<C> {
            uopt: 0,
            ucrit: 0,
            ulow: 0,
            ki: 0,
            kcrit: 0,
            klow: 0,
            klin: 0,
            beta: 0,
            ri: 0,
            t_crit: 0,
        }
    }

    public(friend) fun update_interest_rate<C>(now: u64, total_deposits: u128, total_borrows: u128, last_updated: u64): u64 acquires Config {
        let config_ref = borrow_global_mut<Config<C>>(@leizd);
        let (rcomp,_,_,_) = calc_compound_interest_rate<C>(config_ref, total_deposits, total_borrows, last_updated, now);
        rcomp
    }

    public fun calc_compound_interest_rate<C>(config_ref: &Config<C>, total_deposits: u128, total_borrows: u128, last_updated: u64, now: u64): (u64, u64, u64, bool) {
        let time = now - last_updated;
        let u = math::utilization(total_deposits, total_borrows);
        let slope_i = config_ref.ki * (u - config_ref.uopt) / DECIMAL_PRECISION;

        let ri = config_ref.ri;
        let t_crit = config_ref.t_crit;
        let rp;
        let slope;
        
        if (u > config_ref.ucrit) {
            rp = config_ref.kcrit * (DECIMAL_PRECISION + config_ref.t_crit) / DECIMAL_PRECISION * (u - config_ref.ucrit) / DECIMAL_PRECISION;
            slope = slope_i + config_ref.kcrit * config_ref.beta / DECIMAL_PRECISION * (u - config_ref.ucrit) / DECIMAL_PRECISION;
            t_crit = t_crit + config_ref.beta * time;
        } else {
            rp = math::min(0, config_ref.kcrit * (u - config_ref.ulow) / DECIMAL_PRECISION);
            slope = slope_i;
            t_crit = math::max(0, t_crit - config_ref.beta * time);
        };
        
        let rlin = config_ref.klin * u / DECIMAL_PRECISION;
        ri = math::max(ri, rlin);
        let r0 = ri + rp;
        let r1 = r0 + slope * time;

        let x;
        if (r0 >= rlin && r1 >= rlin) {
            x = (r0 + r1) * time / 2;
        } else if (r0 < rlin && r1 < rlin) {
            x = rlin * time;
        } else if (r0 >= rlin && r1 < rlin) {
            x = rlin * time - (r0 - rlin) * (r0 - rlin) / slope / 2;
        } else {
            x = rlin * time + (r1 - rlin) * (r1 - rlin) / slope / 2;
        };

        ri = math::max(ri + slope_i * time, rlin);
        let (rcomp, overflow) = calc_rcomp(total_deposits, total_borrows, x);

        if (overflow) {
            ri = 0;
            t_crit = 0;
        };

        (rcomp, ri, t_crit, overflow)
    }

    fun calc_rcomp(total_deposits: u128, total_borrows: u128, x: u64): (u64,bool) {

        let rcomp;
        let overflow;
        if (x >= X_MAX) {
            rcomp = math::pow(2, 16) * DECIMAL_PRECISION;
            overflow = true;
        } else {
            // TODO: exp
            total_deposits;
            total_borrows;
            rcomp = DECIMAL_PRECISION / 1000 * 2; // 2%
            overflow = false;
        };

        (rcomp, overflow)
    }

}