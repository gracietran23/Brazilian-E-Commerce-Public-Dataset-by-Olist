-- A. Check and convert data type
ALTER TABLE orders ALTER COLUMN order_purchase_timestamp DATETIME;
ALTER TABLE orders ALTER COLUMN order_approved_at DATETIME;
ALTER TABLE orders ALTER COLUMN order_delivered_carrier_date DATETIME;
ALTER TABLE orders ALTER COLUMN order_delivered_customer_date DATETIME;
ALTER TABLE orders ALTER COLUMN order_estimated_delivery_date DATETIME;


-- B. SQL query
-- 1. Monthly revenue trend
WITH monthly_revenue as(
	SELECT 
		year(order_purchase_timestamp) as y, 
		month(order_purchase_timestamp) as m, 
		sum(price + freight_value) as monthly_sales
	FROM orders o 
	join order_items i on o.order_id = i.order_id
	WHERE order_status = 'delivered'
	GROUP BY year(order_purchase_timestamp), month(order_purchase_timestamp)
)
SELECT 
	y,
	m,
	monthly_sales,
	round(((monthly_sales - lag(monthly_sales) over (ORDER BY y,m))
	/ (lag(monthly_sales) over (ORDER BY y,m)) * 100),3) as 'growth_rate (%)'
	
FROM monthly_revenue;


-- 2. Top product categories
WITH category_revenue AS (
    SELECT
        YEAR(o.order_purchase_timestamp) AS order_year,
        p.product_category_name_english AS category,
        SUM(i.price + i.freight_value) AS revenue
    FROM orders o
    JOIN order_items i
        ON o.order_id = i.order_id
    JOIN products p
        ON i.product_id = p.product_id
    WHERE o.order_status = 'delivered'
    GROUP BY
        YEAR(o.order_purchase_timestamp),
        p.product_category_name_english
),

ranked_categories AS (
    SELECT *,
        RANK() OVER(
            PARTITION BY order_year
            ORDER BY revenue DESC
        ) AS category_rank
    FROM category_revenue
)

SELECT *
FROM ranked_categories
WHERE category_rank <= 5
ORDER BY order_year, category_rank;


-- 3. Revenue by city
SELECT
    c.customer_state,
    SUM(i.price + i.freight_value) AS revenue,
    ROUND(
        SUM(i.price + i.freight_value) * 100.0
        /
        SUM(SUM(i.price + i.freight_value))
            OVER(),
        2
    ) AS percentage_account_for
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items i ON o.order_id = i.order_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state
ORDER BY revenue DESC;


-- 4. Peak ordering periods
SELECT 
    DATEPART(HOUR, o.order_purchase_timestamp) AS purchase_hour,
    COUNT(DISTINCT o.order_id) AS total_orders,
    AVG(p.total_payment) AS avg_order_value
FROM orders o
JOIN (
    SELECT order_id, SUM(payment_value) AS total_payment 
    FROM order_payments 
    GROUP BY order_id
) p ON o.order_id = p.order_id
WHERE o.order_status != 'canceled'
GROUP BY DATEPART(HOUR, o.order_purchase_timestamp)
ORDER BY total_orders desc;


-- 5. Recency, frequency, monetary of each customer
WITH count_sum_purchase as(
	SELECT 
        c.customer_unique_id, 
        max(order_purchase_timestamp) as recency, 
        COUNT(distinct o.order_id) as frequency, 
        sum(price + freight_value) as monetary
	FROM customers c join orders o on c.customer_id = o.customer_id
	join order_items i on i.order_id = o.order_id
	GROUP BY c.customer_unique_id
)
SELECT * 
FROM count_sum_purchase cs
ORDER BY monetary desc;


-- 6. Customer retention rate
WITH customer_stats as(
	SELECT 
		customer_city,
		customer_unique_id,
        COUNT(order_id) AS orders_per_customer
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY customer_city, customer_unique_id
),
retention_rate_per_city as(
	SELECT 
		customer_city,
		COUNT(customer_unique_id) as total_customers,
		SUM(CASE WHEN orders_per_customer >= 2 THEN 1 ELSE 0 END) AS returning_customers
	FROM customer_stats
	GROUP BY customer_city
),
top_10_most_crowded_city as(
	SELECT 
		customer_city, 
		total_customers, 
		returning_customers, 
		rank() over(ORDER BY total_customers desc) as city_rank
	FROM retention_rate_per_city
)

SELECT 
	customer_city, 
	total_customers,
	cast(returning_customers * 100.0 / total_customers AS DECIMAL(10, 2)) as retention_rate_percentage
FROM top_10_most_crowded_city
WHERE city_rank <= 10
ORDER BY retention_rate_percentage desc


-- 7. Delivery delay rate by city
WITH delivery_status AS (
    SELECT
        c.customer_state,
        CASE
            WHEN o.order_delivered_customer_date >
                 o.order_estimated_delivery_date
            THEN 1
            ELSE 0
        END AS is_late
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
)

SELECT
    customer_state AS state_id,
    COUNT(*) AS total_orders,
    SUM(is_late) AS late_orders,
    ROUND(
        SUM(is_late) * 100.0 / COUNT(*),
        2
    ) AS late_delivery_rate_pct
FROM delivery_status
GROUP BY customer_state
ORDER BY late_delivery_rate_pct DESC;


-- 8. Delivery delay vs review score
SELECT 
    review_score,
    delivery_state,
    COUNT(order_id) AS total_orders,
    ROUND(
        COUNT(order_id) * 100.0 / SUM(COUNT(order_id)) OVER (PARTITION BY review_score), 
        2
    ) AS percentage
FROM (
    SELECT 
        o.order_id, 
        review_score,
        CASE 
            WHEN order_delivered_customer_date <= order_estimated_delivery_date THEN 'On time/Early'
            ELSE 'Late'
        END AS delivery_state
    FROM orders o join order_reviews r on o.order_id = r.order_id
	where order_delivered_customer_date is not null
	
) AS subquery
GROUP BY 
    review_score, 
    delivery_state
ORDER BY 
    review_score DESC, 
    delivery_state;


-- 9. Seller rating performance
SELECT 
	seller_id, 
	COUNT(distinct i.order_id) as number_of_orders, 
	avg(cast(r.review_score as decimal(10,2))) as avg_review_score,
    ROUND(
        SUM(
            CASE
                WHEN review_score <= 2
                THEN 1
                ELSE 0
            END
        ) * 100.0
        /
        COUNT(*),
        2
    ) AS low_rating_pct
FROM order_items i 
join order_reviews r on r.order_id = i.order_id
GROUP BY seller_id
HAVING COUNT(*) >= 10
ORDER BY low_rating_pct desc;


-- 10. Seller contribution to low-rated orders
WITH seller_low_rating AS (
    SELECT
        seller_id,
        COUNT(DISTINCT i.order_id) AS low_rated_orders
    FROM order_items i
    JOIN order_reviews r ON i.order_id = r.order_id
    WHERE r.review_score <= 2
    GROUP BY seller_id
)

SELECT
    seller_id,
    low_rated_orders

FROM seller_low_rating
ORDER BY low_rated_orders DESC;