mod contracts {
    mod memecoin;
    mod relaunch;
    pub mod internal_swap_pool;
    pub mod router;
    pub mod test_token;
}

mod interfaces {
    pub mod Iisp;
    pub mod Imemecoin;
    pub mod Irelaunch;
    pub mod Irouter;
}

#[cfg(test)]
mod tests{
    pub mod router_swap_test;
}


